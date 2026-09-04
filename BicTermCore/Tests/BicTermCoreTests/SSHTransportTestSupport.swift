import CryptoKit
import Foundation
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
    static let coderStubPort = 18080

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
            keyReference: keyReference
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
}

struct StaticKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        key
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
