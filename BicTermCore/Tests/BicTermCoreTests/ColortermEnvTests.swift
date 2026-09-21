import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import BicTermCore

private enum ColortermTestTimeout: Error { case operationDidNotComplete }

/// T2: `COLORTERM=truecolor` advertisement on both session-open paths —
/// direct (`SSHTransport.openSessionAndActivate`) and jump
/// (`NIOJumpHopConnection.openSession`).
///
/// Two layers of proof:
/// - Hermetic unit tests against an in-process NIOSSH server that records
///   session-channel requests: they pin the wire shape (name, value,
///   `wantReply: false`) and the pty → env → shell ordering, and prove an
///   env denial can never block or fail session setup because no env reply
///   is awaited.
/// - Live fixture integration tests: `printenv COLORTERM` must report
///   `truecolor` on the direct hop-1 PTY (12222) and on the two-hop
///   hop-2-via-hop-1 PTY (12223 via 12222).
final class ColortermEnvTests: XCTestCase {
    private static let unitUsername = "ctuser"
    private static let unitPassword = "colorterm-unit-password"
    private static let unitPasswordTag = "colorterm-unit-tag"

    private var collectors: [Task<Void, Never>] = []
    private var liveTransports: [any SSHSessionTransport] = []

    override func tearDown() async throws {
        for transport in liveTransports {
            await transport.close()
        }
        liveTransports = []
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    // MARK: - Unit: wire shape and ordering (in-process recording server)

    func testDirectSessionEnvRequestIsColortermTruecolorWithoutReply() async throws {
        let server = ColortermRecordingServer(username: Self.unitUsername, password: Self.unitPassword)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await makeUnitTransport(server: server, port: port)
        liveTransports.append(transport)
        let connection = try makeUnitConnection(port: port)
        try await bounded {
            try await transport.connect(to: connection, cols: 80, rows: 24)
        }

        XCTAssertEqual(
            server.requests,
            [
                .pty,
                .env(name: "COLORTERM", value: "truecolor", wantReply: false),
                .shell,
            ],
            "direct session-open must send exactly pty → COLORTERM=truecolor (wantReply: false) → shell"
        )
    }

    func testJumpSessionEnvRequestIsColortermTruecolorWithoutReply() async throws {
        let server = ColortermRecordingServer(username: Self.unitUsername, password: Self.unitPassword)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let dialer = NIOJumpDialer(
            hostKeyVerifier: try await makeUnitVerifier(server: server, port: port),
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: InMemoryPasswordStore([Self.unitPasswordTag: Self.unitPassword])
        )
        let hop = try await dialer.connectTCP(to: JumpHopEndpoint(
            host: "127.0.0.1",
            port: port,
            username: Self.unitUsername,
            offersKeys: false,
            passwordTag: Self.unitPasswordTag
        ))
        let session = try await bounded {
            try await hop.openSession(cols: 80, rows: 24)
        }
        await session.close()
        await hop.close()

        XCTAssertEqual(
            server.requests,
            [
                .pty,
                .env(name: "COLORTERM", value: "truecolor", wantReply: false),
                .shell,
            ],
            "jump session-open must send exactly pty → COLORTERM=truecolor (wantReply: false) → shell"
        )
    }

    // MARK: - Unit: denial can never block or fail setup

    func testEnvDenialCannotBlockOrFailSessionSetup() async throws {
        // The recording server never honors the env request and — because
        // the request must carry wantReply: false — never replies to it:
        // OpenSSH's silent-denial posture for a variable not matched by
        // AcceptEnv. Setup must complete anyway (no env reply is awaited),
        // and the shell must be fully live afterwards.
        let server = ColortermRecordingServer(username: Self.unitUsername, password: Self.unitPassword)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await makeUnitTransport(server: server, port: port)
        liveTransports.append(transport)
        let connection = try makeUnitConnection(port: port)
        try await bounded {
            try await transport.connect(to: connection, cols: 80, rows: 24)
        }

        // The env request really was sent (and denied), not skipped.
        XCTAssertTrue(
            server.requests.contains { request in
                if case let .env(name, _, wantReply) = request {
                    return name == "COLORTERM" && !wantReply
                }
                return false
            },
            "the denied env request must have been observed by the server"
        )

        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        let greeted = await waitForContent(
            sink: sink,
            marker: "colorterm-recorder ready",
            timeoutMilliseconds: 8000
        )
        XCTAssertTrue(greeted, "session must be live despite the denied env request")

        try await transport.send(Data("printf colorterm-denial-ok\n".utf8))
        let echoed = await waitForContent(sink: sink, marker: "colorterm-denial-ok", timeoutMilliseconds: 8000)
        XCTAssertTrue(echoed, "shell round-trip must work despite the denied env request")
    }

    // MARK: - Integration: fixture sshds

    func testDirectPTYAdvertisesColortermTruecolor() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        liveTransports.append(transport)
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)

        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        try await quiesceSession(transport, sink: sink)

        try await transport.send(Data("printenv COLORTERM; printf '__CT_DONE__\\n'\n".utf8))
        let done = await waitForContent(sink: sink, marker: "__CT_DONE__", timeoutMilliseconds: 8000)
        XCTAssertTrue(done, "printenv COLORTERM never completed on the direct fixture PTY")
        let directOutput = printenvOutput(from: await sink.snapshot())
        XCTAssertEqual(
            directOutput,
            "truecolor",
            "printenv COLORTERM must report truecolor on the direct hop-1 PTY (12222)"
        )
    }

    func testJumpPTYAdvertisesColortermTruecolor() async throws {
        let builder = JumpChainBuilder(
            hostKeyVerifier: try await JumpFixture.makeVerifier(),
            authenticationKeyProvider: try await JumpFixture.makeRecordingProvider(),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        let transport = try await builder.build(
            connection: JumpFixture.twoHopConnection(),
            cols: 80,
            rows: 24
        )
        liveTransports.append(transport)

        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        try await quiesceSession(transport, sink: sink)

        try await transport.send(Data("printenv COLORTERM; printf '__CT_DONE__\\n'\n".utf8))
        let done = await waitForContent(sink: sink, marker: "__CT_DONE__", timeoutMilliseconds: 8000)
        XCTAssertTrue(done, "printenv COLORTERM never completed on the jump fixture PTY")
        let jumpOutput = printenvOutput(from: await sink.snapshot())
        XCTAssertEqual(
            jumpOutput,
            "truecolor",
            "printenv COLORTERM must report truecolor on the hop-2-via-hop-1 PTY (12223 via 12222)"
        )
    }

    // MARK: - Helpers

    private func makeUnitVerifier(server: ColortermRecordingServer, port: Int) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(host: "127.0.0.1", port: port, key: blob, algorithm: String(components[0]))
        return verifier
    }

    private func makeUnitTransport(server: ColortermRecordingServer, port: Int) async throws -> SSHTransport {
        SSHTransport(
            hostKeyVerifier: try await makeUnitVerifier(server: server, port: port),
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: InMemoryPasswordStore([Self.unitPasswordTag: Self.unitPassword])
        )
    }

    private func makeUnitConnection(port: Int) throws -> Connection {
        try Connection(
            name: "colorterm-unit",
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: Self.unitUsername,
            offersKeys: false,
            passwordTag: Self.unitPasswordTag
        )
    }

    /// Runs `operation` with a bounded wait: a session-open path that hangs
    /// (for example, one that awaited an env reply that never comes) fails
    /// the test with a clear error instead of stalling the whole suite.
    private func bounded<T: Sendable>(
        timeoutMilliseconds: UInt64 = 10_000,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return nil
            }
            do {
                // `?? nil` flattens T??: the operation's result, or nil when
                // the timer won the race.
                guard let result = try await group.next() ?? nil else {
                    throw ColortermTestTimeout.operationDidNotComplete
                }
                group.cancelAll()
                // Drain the cancelled timer; its CancellationError is expected.
                do {
                    _ = try await group.next()
                } catch is CancellationError {
                    // The cancelled timer — expected.
                }
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// The printenv output: the non-empty lines BEFORE the completion
    /// sentinel. Everything after the sentinel is shell-prompt noise — the
    /// fixture login shell's theme prints a `%` filler line before each
    /// prompt, which must not glue onto the measured output.
    private func printenvOutput(from raw: Data) -> String {
        let text = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let sentinel = lines.firstIndex(of: "__CT_DONE__") {
            lines = Array(lines[..<sentinel])
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - In-process recording server

/// Test-only NIOSSH server for COLORTERM env-request assertions: records
/// every session-channel request in arrival order, grants pty and shell,
/// greets on shell, and echoes channel data. An env request is answered
/// with CHANNEL_FAILURE only when the client asked for a reply — OpenSSH's
/// denial shape for a variable not matched by AcceptEnv — so a client that
/// wrongly sets wantReply: true observes the denial, while the correct
/// wantReply: false request is silently dropped (no reply at all).
private final class ColortermRecordingServer: @unchecked Sendable {
    // @unchecked Sendable: lock-confined recorder and running state; NIO
    // objects are confined to the server channel's EventLoop by construction
    // (same idiom as LoopbackPasswordSSHServer).
    enum RecordedRequest: Equatable {
        case pty
        case env(name: String, value: String, wantReply: Bool)
        case shell
    }

    /// Bytes emitted once a shell is granted — the "session is live" marker.
    static let greeting = "colorterm-recorder ready\r\n"

    private let username: String
    private let password: String
    private let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: (any Channel)?

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// `"algorithm base64-wire-blob"` in authorized_keys format.
    var hostKeyOpenSSH: String {
        String(openSSHPublicKey: hostKey.publicKey)
    }

    /// Session-channel requests in arrival order.
    var requests: [RecordedRequest] {
        lock.withLock { recordedRequests }
    }

    /// Binds `127.0.0.1:0` (ephemeral) and returns the bound port.
    func start() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let authDelegate = AcceptOnePasswordDelegate(username: username, password: password)
        let hostKey = self.hostKey
        let recorder = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [hostKey],
                            userAuthDelegate: authDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            guard channelType == .session else {
                                return child.eventLoop.makeFailedFuture(TransportError.channelDenied)
                            }
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(
                                    EnvRecordingSessionHandler(recorder: recorder)
                                )
                            }
                        }
                    ))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            lock.withLock {
                serverChannel = channel
                self.group = group
            }
            return channel.localAddress?.port ?? 0
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        let taken = lock.withLock { () -> ((any Channel)?, MultiThreadedEventLoopGroup?) in
            let state = (serverChannel, group)
            serverChannel = nil
            self.group = nil
            return state
        }
        if let channel = taken.0 { try? await channel.close().get() }
        if let group = taken.1 { try? await group.shutdownGracefully() }
    }

    fileprivate func record(_ request: RecordedRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }
}

/// Server-side auth delegate: accepts exactly one username+password pair.
private final class AcceptOnePasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username,
              case .password(let offer) = request.request,
              offer.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

/// Session channel behavior: record pty/env/shell requests in order, grant
/// pty/shell (success replies only when the client asked for one), greet on
/// shell, then echo data back. Env requests are never honored; a wantReply
/// env request additionally gets CHANNEL_FAILURE (OpenSSH denial shape).
private final class EnvRecordingSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let recorder: ColortermRecordingServer

    init(recorder: ColortermRecordingServer) {
        self.recorder = recorder
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            recorder.record(.pty)
            if pty.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case let env as SSHChannelRequestEvent.EnvironmentRequest:
            recorder.record(.env(name: env.name, value: env.value, wantReply: env.wantReply))
            if env.wantReply {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        case let shell as SSHChannelRequestEvent.ShellRequest:
            recorder.record(.shell)
            if shell.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            var buffer = context.channel.allocator.buffer(capacity: ColortermRecordingServer.greeting.utf8.count)
            buffer.writeString(ColortermRecordingServer.greeting)
            context.writeAndFlush(
                wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
                promise: nil
            )
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer = message.data else { return }
        context.writeAndFlush(data, promise: nil)
    }
}
