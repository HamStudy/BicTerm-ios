import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// T2 of the three-biometric-prompts-per-connection fix: the terminal
/// connect path routes every handshake of ONE connect action through a
/// single ``ConnectScopedKeyResolution`` created per transport by
/// ``SSHSessionTransportFactory``. Proofs: a direct connect resolves each
/// key reference exactly once; a reconnect (fresh `makeTransport`) is a
/// fresh scope and re-evaluates; a two-hop jump chain (hop, hop,
/// destination = THREE handshakes) resolves each reference exactly once
/// across the whole build; and a failed connect invalidates the scope so
/// the next attempt re-resolves instead of reusing the cached key.
final class ConnectScopedTerminalAuthTests: XCTestCase {
    private static let keyReference = "fixture-ed25519"

    // MARK: (a) Direct connect

    func testDirectConnectResolvesOncePerConnectAndReconnectResolvesFresh() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let counting = CountingKeyProvider(underlying: StaticKeyProvider(key: key))
        let server = LoopbackPasswordSSHServer(
            username: "pwduser", password: "unused-under-key-auth",
            keyAuthentication: .acceptedPublicKeys([try Self.publicKeyBlob(of: key)])
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: try await Self.verifier(trusting: server, on: port),
            authenticationKeyProvider: counting,
            passwordStore: InMemoryPasswordStore(),
            metadataProvider: FixtureKeyMetadataProvider(references: [Self.keyReference])
        )
        let connection = try Connection(
            name: "scoped-direct", type: .ssh, host: "127.0.0.1", port: port,
            username: "pwduser", customKeys: [Self.keyReference]
        )

        let first = try factory.makeTransport(for: connection)
        try await first.connect(to: connection, cols: 80, rows: 24)
        await first.close()
        XCTAssertEqual(counting.callCount(for: Self.keyReference), 1, "one direct handshake = one resolution")
        XCTAssertEqual(server.authenticatedConnectionCount, 1)

        // Reconnect shape: every makeTransport is a fresh connect intent
        // with a fresh scope — the second connect must re-evaluate the
        // underlying provider, never reuse the first transport's key.
        let second = try factory.makeTransport(for: connection)
        try await second.connect(to: connection, cols: 80, rows: 24)
        await second.close()
        XCTAssertEqual(counting.callCount(for: Self.keyReference), 2, "reconnect = fresh scope = fresh evaluation")
        XCTAssertEqual(server.authenticatedConnectionCount, 2)
    }

    // MARK: (b) HEADLINE — jump chain, one resolution across all handshakes

    func testTwoHopJumpChainResolvesOncePerReferenceAcrossThreeHandshakes() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let counting = CountingKeyProvider(underlying: StaticKeyProvider(key: key))
        let destination = LoopbackPasswordSSHServer(
            username: "pwduser", password: "unused-under-key-auth",
            keyAuthentication: .acceptedPublicKeys([try Self.publicKeyBlob(of: key)])
        )
        let destinationPort = try await destination.start(port: 0)
        defer { Task { await destination.stop() } }
        let verifier = try await JumpFixture.makeVerifier()
        try await Self.trust(server: destination, on: destinationPort, in: verifier)
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: counting,
            passwordStore: InMemoryPasswordStore(),
            metadataProvider: FixtureKeyMetadataProvider(references: [Self.keyReference])
        )
        let connection = try Connection(
            name: "scoped-jump", type: .ssh, host: "127.0.0.1", port: destinationPort,
            username: "pwduser", customKeys: [Self.keyReference],
            jumpChain: [
                Hop(host: "127.0.0.1", port: 12223, username: SSHTestFixture.username, customKeys: [Self.keyReference]),
                Hop(host: "127.0.0.1", port: 12222, username: SSHTestFixture.username, customKeys: [Self.keyReference]),
            ]
        )

        let transport = try factory.makeTransport(for: connection)
        try await transport.connect(to: connection, cols: 80, rows: 24)

        XCTAssertEqual(
            counting.callCount(for: Self.keyReference), 1,
            "the full 3-handshake build (hop 12223, hop 12222, loopback destination) must share ONE key resolution"
        )
        XCTAssertEqual(destination.authenticatedConnectionCount, 1, "the destination handshake must have completed")
        await transport.close()
    }

    // MARK: (c) Connect failure invalidates the scope

    func testFailedConnectInvalidatesScopeSoRetryResolvesAgain() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let counting = CountingKeyProvider(underlying: StaticKeyProvider(key: key))
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: try await JumpFixture.makeVerifier(),
            authenticationKeyProvider: counting,
            passwordStore: InMemoryPasswordStore(),
            metadataProvider: FixtureKeyMetadataProvider(references: [Self.keyReference])
        )
        // Destination port 1: nothing listens there, so the chain dies at
        // the final forward — AFTER both hop handshakes resolved the key.
        let connection = try Connection(
            name: "scoped-dead-destination", type: .ssh, host: "127.0.0.1", port: 1,
            username: "pwduser", customKeys: [Self.keyReference],
            jumpChain: [
                Hop(host: "127.0.0.1", port: 12223, username: SSHTestFixture.username, customKeys: [Self.keyReference]),
                Hop(host: "127.0.0.1", port: 12222, username: SSHTestFixture.username, customKeys: [Self.keyReference]),
            ]
        )

        let transport = try factory.makeTransport(for: connection)
        for attempt in 1...2 {
            do {
                try await transport.connect(to: connection, cols: 80, rows: 24)
                XCTFail("attempt \(attempt): the dead destination port must fail the connect")
            } catch {
                // expected: the final forward reaches a port where nothing listens
            }
        }
        XCTAssertEqual(
            counting.callCount(for: Self.keyReference), 2,
            "each failed connect re-resolved — failure must invalidate the scope; a surviving cache would keep this at 1"
        )
    }

    // MARK: Helpers

    private static func publicKeyBlob(of key: NIOSSHPrivateKey) throws -> Data {
        let components = String(openSSHPublicKey: key.publicKey).split(separator: " ", maxSplits: 1)
        return try XCTUnwrap(Data(base64Encoded: String(components[1])))
    }

    private static func verifier(trusting server: LoopbackPasswordSSHServer, on port: Int) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        try await trust(server: server, on: port, in: verifier)
        return verifier
    }

    private static func trust(
        server: LoopbackPasswordSSHServer,
        on port: Int,
        in verifier: HostKeyVerifier
    ) async throws {
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(host: "127.0.0.1", port: port, key: blob, algorithm: String(components[0]))
    }
}
