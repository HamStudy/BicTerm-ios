import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import BicTermCore

enum SSHTestFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let hop1Host = "127.0.0.1"
    static let hop1Port = 12222
    static let hop2Port = 12223

    static let normalHostKeyFingerprint = "SHA256:pT2cNum6IkFhCplSQfWE5oW2CU4Bg51qD1/1HtirjBs"
    static let altHostKeyFingerprint = "SHA256:KFI1+LB+PDwEPIR2F+G3BCOriC0xIqASUsRHhyDsRdk"

    static var username: String {
        // The simulator test host resolves getpwuid()/NSUserName() to an
        // EMPTY name (observed: uid=501, name=""). An empty username makes
        // the fixture sshd srclimit-penalize 127.0.0.1 ("invalid user"),
        // poisoning later tests, so fall back to the checkout path
        // (/Users/<name>/...) — always the user fixtures-up.sh ran as.
        for candidate in [
            ProcessInfo.processInfo.environment["USER"],
            ProcessInfo.processInfo.environment["LOGNAME"],
            NSUserName(),
        ] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        let components = repoRoot.pathComponents
        if components.count > 2, components[0] == "/", components[1] == "Users" {
            return components[2]
        }
        return NSUserName()
    }

    static func makeConnection(keyReference: String = "fixture-ed25519") throws -> Connection {
        try Connection(
            name: "fixture-hop1",
            type: .ssh,
            host: hop1Host,
            port: hop1Port,
            username: username,
            customKeys: [keyReference]
        )
    }

    static func hostPublicKey(_ relativePath: String) throws -> (algorithm: String, blob: Data) {
        let url = repoRoot.appendingPathComponent(relativePath)
        let line = try String(contentsOf: url, encoding: .utf8)
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "SSHTestFixture", code: 1)
        }
        return (String(parts[0]), blob)
    }

    static func makeVerifier(trustingNormalHop1Key: Bool = true) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        if trustingNormalHop1Key {
            let key = try hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
            try await verifier.trust(host: hop1Host, port: hop1Port, key: key.blob, algorithm: key.algorithm)
        }
        return verifier
    }

    static func loadFixtureEd25519Key(_ filename: String = "bicterm-fixture-ed25519") async throws -> NIOSSHPrivateKey {
        let url = repoRoot.appendingPathComponent("Fixtures/keys/\(filename)")
        let parsed = try await OpenSSHPrivateKeyParser().parse(Data(contentsOf: url))
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    static func hop1ActiveConfig() -> String {
        let url = repoRoot.appendingPathComponent("Fixtures/run/hop1.active_config")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The ONLY permitted fixture write: append a key line to hop1's
    /// authorized_keys, always restoring the original bytes afterwards.
    static func withHop1AuthorizedKeyAdded(_ line: String, body: () async throws -> Void) async throws {
        let url = repoRoot.appendingPathComponent("Fixtures/sshd/authorized_keys_hop1")
        let original = try Data(contentsOf: url)
        var modified = original
        modified.append(Data((line + "\n").utf8))
        try modified.write(to: url)
        defer { try? original.write(to: url) }
        try await body()
    }
}

actor EphemeralHostKeyStore: HostKeyStoreProtocol {
    private var records: [HostKeyIdentity: HostKeyRecord] = [:]

    func loadAll() async throws(PersistenceError) -> [HostKeyRecord] {
        Array(records.values)
    }

    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord? {
        records[HostKeyIdentity(host: host, port: port)]
    }

    func save(_ record: HostKeyRecord) async throws(PersistenceError) {
        records[record.identity] = record
    }

    func forget(host: String, port: Int) async throws(PersistenceError) {
        records[HostKeyIdentity(host: host, port: port)] = nil
    }
}

struct StaticKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        key
    }
}

struct FixtureKeyMetadataProvider: SSHKeyMetadataProviding {
    var references = ["fixture-ed25519", "fixture-ed25519-hop2-unauthorized", "fixture-p256"]

    func availableKeys() async throws -> [KeyMetadata] {
        references.map {
            KeyMetadata(reference: $0, label: $0, algorithm: .ed25519,
                        fingerprint: "fixture", publicKeyBlob: Data(), requiresBiometry: false)
        }
    }
}

actor SSHOutputSink {
    private var buffer = Data()
    private(set) var isFinished = false

    func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    func markFinished() {
        isFinished = true
    }

    func reset() {
        buffer = Data()
    }

    func snapshot() -> Data {
        buffer
    }
}

func startCollecting(from transport: SSHTransport, into sink: SSHOutputSink) async -> Task<Void, Never> {
    let stream = await transport.output
    return Task {
        for await chunk in stream {
            await sink.append(chunk)
        }
        await sink.markFinished()
    }
}

func waitForFinished(sink: SSHOutputSink, timeoutMilliseconds: UInt64 = 6000) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(timeoutMilliseconds)
    while clock.now < deadline {
        if await sink.isFinished { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await sink.isFinished
}

func waitForContent(sink: SSHOutputSink, marker: String, timeoutMilliseconds: UInt64 = 8000) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(timeoutMilliseconds)
    while clock.now < deadline {
        let text = String(decoding: await sink.snapshot(), as: UTF8.self)
        if text.contains(marker) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

func assertThrowsSSHError(
    _ expected: SSHTransportError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as SSHTransportError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

// MARK: - UDS test scaffolding (T8)

/// Per-session socket path (`bicterm-uds-<uuid>.sock`). Tests bind under
/// `Fixtures/run` (repo-local, gitignored) because iOS sandbox tmp paths
/// exceed the 104-byte `sockaddr_un.sun_path` limit; Docs/SECURITY.md
/// documents that constraint.
func makeTestSocketPath() -> String {
    SSHTestFixture.repoRoot
        .appendingPathComponent("Fixtures/run/bicterm-uds-\(UUID().uuidString).sock")
        .path
}

func removeIfExists(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Test-side unix-domain-socket listener that bridges each accepted
/// connection to a loopback TCP target. Embodies the per-session bridge
/// contract: stale leftover file at the path is unlinked before bind,
/// the socket carries 0600, and `stop()` removes the socket path.
final class UDSTestBridge: @unchecked Sendable {
    // @unchecked Sendable: start/stop are called serially from async tests;
    // the child-channel registry is guarded by sync NSLock helpers
    // (same idiom as LoopbackPasswordSSHServer) — NSLock is unavailable
    // from async contexts, so locked state never straddles an await.
    let path: String
    private let targetHost: String
    private let targetPort: Int
    private let lock = NSLock()
    private var children: [ObjectIdentifier: any Channel] = [:]
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: (any Channel)?

    init(path: String, targetHost: String = "127.0.0.1", targetPort: Int) {
        self.path = path
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    private func noteChild(_ channel: any Channel) {
        lock.lock()
        children[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    private func dropChild(_ channel: any Channel) {
        lock.lock()
        children.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    private func takeChildren() -> [any Channel] {
        lock.lock()
        defer { lock.unlock() }
        let current = Array(children.values)
        children = [:]
        return current
    }

    func start() async throws {
        removeIfExists(path)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let targetHost = self.targetHost
        let targetPort = self.targetPort
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { [self] channel in
                noteChild(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        UDSInboundRelay(
                            targetHost: targetHost,
                            targetPort: targetPort,
                            onChildInactive: { [weak self] ended in self?.dropChild(ended) }
                        )
                    )
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.bind(to: SocketAddress(unixDomainSocketPath: path)).get()
        } catch {
            try? await group.shutdownGracefully()
            removeIfExists(path)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        self.group = group
        serverChannel = channel
    }

    /// Closes the listener AND every still-open bridged child before the
    /// group shuts down, so no handler ever fires on a dead EventLoop.
    func stop() async {
        if let serverChannel {
            self.serverChannel = nil
            try? await serverChannel.close().get()
        }
        for child in takeChildren() {
            try? await child.close().get()
        }
        if let group {
            self.group = nil
            try? await group.shutdownGracefully()
        }
        removeIfExists(path)
    }
}

/// Pipes inbound bytes from an accepted UDS client into a freshly dialed TCP
/// target and vice versa. The target dial runs on the accepted channel's own
/// EventLoop (`ClientBootstrap(group: context.eventLoop)`), so every handler
/// callback — both relays included — stays confined to one loop. Bytes
/// arriving before the target dial completes are buffered (the SSH client
/// identification line lands immediately).
final class UDSInboundRelay: ChannelInboundHandler, @unchecked Sendable {
    // @unchecked Sendable: all state mutations are confined to the accepted
    // channel's EventLoop by construction (see type doc).
    typealias InboundIn = ByteBuffer

    private let targetHost: String
    private let targetPort: Int
    private let onChildInactive: @Sendable (any Channel) -> Void
    private var peer: (any Channel)?
    private var pendingWrites: [ByteBuffer] = []

    init(
        targetHost: String,
        targetPort: Int,
        onChildInactive: @escaping @Sendable (any Channel) -> Void
    ) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.onChildInactive = onChildInactive
    }

    func channelActive(context: ChannelHandlerContext) {
        let udsChannel = context.channel
        ClientBootstrap(group: context.eventLoop)
            .connect(host: targetHost, port: targetPort)
            .whenComplete { result in
                switch result {
                case .failure:
                    context.close(promise: nil)
                case .success(let target):
                    target.pipeline.addHandler(UDSPeerRelay(peer: udsChannel)).whenComplete { _ in
                        self.peer = target
                        let buffered = self.pendingWrites
                        self.pendingWrites = []
                        for buffer in buffered {
                            target.writeAndFlush(buffer, promise: nil)
                        }
                    }
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let peer {
            peer.writeAndFlush(buffer, promise: nil)
        } else {
            pendingWrites.append(buffer)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onChildInactive(context.channel)
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Reverse direction of the relay: TCP target -> UDS client. Runs on the
/// same EventLoop as ``UDSInboundRelay`` by construction.
final class UDSPeerRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: any Channel

    init(peer: any Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
