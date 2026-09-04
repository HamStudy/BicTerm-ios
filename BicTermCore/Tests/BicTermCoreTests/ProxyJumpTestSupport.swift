import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

// MARK: - Recording key provider

/// Maps keyReference → key and records every resolution call, proving the
/// builder passes each hop's OWN keyReference (no credential sharing).
final class RecordingKeyProvider: SSHAuthenticationKeyProvider, @unchecked Sendable {
    struct Call: Equatable {
        let reference: String
        let reason: String
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private let keys: [String: NIOSSHPrivateKey]

    init(keys: [String: NIOSSHPrivateKey]) {
        self.keys = keys
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        lock.withLock { recordedCalls.append(Call(reference: reference, reason: reason)) }
        guard let key = keys[reference] else { throw KeyRepositoryError.keyNotFound }
        return key
    }
}

// MARK: - Fixture helpers

enum JumpFixture {
    static let host = "127.0.0.1"
    static let hop1Port = 12222
    static let hop2Port = 12223

    static let goodKeyReference = "fixture-ed25519"
    static let hop2UnauthorizedKeyReference = "fixture-ed25519-hop2-unauthorized"

    static var jumpHop1: Hop {
        Hop(host: host, port: hop1Port, username: SSHTestFixture.username, keyReference: goodKeyReference)
    }

    static func twoHopConnection(destinationKeyReference: String = goodKeyReference) throws -> Connection {
        try Connection(
            name: "two-hop-fixture",
            type: .ssh,
            host: host,
            port: hop2Port,
            username: SSHTestFixture.username,
            keyReference: destinationKeyReference,
            jumpChain: [jumpHop1]
        )
    }

    /// Loads the two fixture client keys under distinct references.
    static func makeRecordingProvider() async throws -> RecordingKeyProvider {
        let good = try await SSHTestFixture.loadFixtureEd25519Key("bicterm-fixture-ed25519")
        let unauthorized = try await SSHTestFixture.loadFixtureEd25519Key("bicterm-fixture-ed25519_hop2_unauthorized")
        return RecordingKeyProvider(keys: [
            goodKeyReference: good,
            hop2UnauthorizedKeyReference: unauthorized,
        ])
    }

    /// Verifier pre-trusting hop1, and hop2 unless disabled.
    static func makeVerifier(trustingHop2: Bool = true) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let hop1Key = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        try await verifier.trust(host: host, port: hop1Port, key: hop1Key.blob, algorithm: hop1Key.algorithm)
        if trustingHop2 {
            let hop2Key = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop2_host_ed25519.pub")
            try await verifier.trust(host: host, port: hop2Port, key: hop2Key.blob, algorithm: hop2Key.algorithm)
        }
        return verifier
    }
}

// MARK: - sshd DEBUG3 log tailing (provenance / cleanup assertions)

func fixtureLogSize(_ filename: String) -> UInt64 {
    let url = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/\(filename)")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
    defer { try? handle.close() }
    return handle.seekToEndOfFile()
}

func fixtureLogAppendage(_ filename: String, from offset: UInt64) -> String {
    let url = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/\(filename)")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    handle.seek(toFileOffset: offset)
    return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
}

/// Polls the appended portion of a fixture log until ANY marker appears.
/// Returns the appended text, or nil on timeout.
func waitForLogContent(
    _ filename: String,
    from offset: UInt64,
    markers: [String],
    timeoutMilliseconds: UInt64 = 8000
) async -> String? {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(timeoutMilliseconds)
    while clock.now < deadline {
        let text = fixtureLogAppendage(filename, from: offset)
        if markers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return text
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
}

// MARK: - Session transport test utilities

func startCollecting(from transport: any SSHSessionTransport, into sink: SSHOutputSink) async -> Task<Void, Never> {
    let stream = await transport.output
    return Task {
        for await chunk in stream {
            await sink.append(chunk)
        }
        await sink.markFinished()
    }
}

/// Neutralizes the interactive shell (T7 pattern) and waits for the
/// split-string ready marker.
func quiesceSession(
    _ transport: any SSHSessionTransport,
    sink: SSHOutputSink,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await transport.send(Data(
        "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"
            .utf8
    ))
    let ready = await waitForContent(sink: sink, marker: "__READY__", timeoutMilliseconds: 8000)
    XCTAssertTrue(ready, "shell did not reach ready marker", file: file, line: line)
    await sink.reset()
}
