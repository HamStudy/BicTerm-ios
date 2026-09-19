import Foundation
import XCTest
@testable import BicTermCore

/// `SSHTransport.connectExecOnly(to:)` — the channel-less establish
/// (dial + handshake + auth, NO session channel) — against the
/// CoderSSHGW-emulation fixture (`LoopbackPasswordSSHServer` with
/// `.lifetimeTotal(1)`): the exec channel must be the connection's FIRST
/// session-type channel open, budget exhaustion must collapse to typed
/// `.channelDenied` with the underlying `NIOSSHError` recorded in
/// `SSHEstablishDiagnostics`, `close()` must tear the channel-less state
/// down cleanly, and the TOFU trust demand must surface typed from the
/// handshake exactly as it does from `connect(to:cols:rows:)`.
final class SSHTransportExecOnlyTests: XCTestCase {
    private static let username = "pwduser"

    override func tearDown() async throws {
        SSHEstablishDiagnostics.shared.removeAll()
    }

    // MARK: Exec as the first (and budgeted) session channel

    func testConnectExecOnlyOpensNoSessionChannelBeforeFirstExec() async throws {
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword,
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let transport = try await makeTransport(for: server, port: port)
        try await transport.connectExecOnly(to: makeConnection(port: port))

        // The exec open is budget slot #1 — it can only succeed because
        // connectExecOnly opened ZERO session channels during establish
        // (a terminal establish would have consumed the slot).
        let session = try await transport.openExecChannel(command: "command -v herdr")
        let stdout = await drainStdout(session)
        XCTAssertEqual(stdout, LoopbackPasswordSSHServer.defaultExecResponse)
        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
        XCTAssertEqual(server.authenticatedConnectionCount, 1)

        await transport.close()
        await server.stop()
    }

    func testSecondExecChannelOnLifetimeBudgetThrowsChannelDeniedAndRecordsUnderlyingError() async throws {
        SSHEstablishDiagnostics.shared.removeAll()
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword,
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let transport = try await makeTransport(for: server, port: port)
        try await transport.connectExecOnly(to: makeConnection(port: port))

        // Budget slot #1: consumed by the first exec channel.
        let first = try await transport.openExecChannel(command: "command -v herdr")
        _ = await drainStdout(first)
        _ = await first.termination()

        // Budget slot #2: refused by the connection's LIFETIME policy.
        // Pins the full chain: budget exhaustion → channel-open failure →
        // typed `.channelDenied` collapse, with the underlying
        // `NIOSSHError.channelSetupRejected` (reason code 2, empty
        // description — the vendored-fork constant) recorded at the
        // exec-open swallow point.
        do {
            _ = try await transport.openExecChannel(command: "command -v herdr")
            XCTFail("lifetimeTotal(1) must refuse the second exec channel open")
        } catch let error as TransportError {
            XCTAssertEqual(error, .channelDenied)
        }
        XCTAssertTrue(
            SSHEstablishDiagnostics.shared.snapshot().contains(
                "exec channel open failed: NIOSSHError.channelSetupRejected: Reason: 2 "
            )
        )

        await transport.close()
        await server.stop()
    }

    // MARK: Teardown

    func testCloseAfterConnectExecOnlyIsCleanAndSubsequentOpsFailTyped() async throws {
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let transport = try await makeTransport(for: server, port: port)
        try await transport.connectExecOnly(to: makeConnection(port: port))
        XCTAssertEqual(server.authenticatedConnectionCount, 1)

        // No session channel was ever opened: tearDown must handle the
        // channel-less state (nil session channel) without crashing.
        await transport.close()

        do {
            _ = try await transport.openExecChannel(command: "command -v herdr")
            XCTFail("exec after close must fail typed")
        } catch let error as TransportError {
            XCTAssertEqual(error, .channelDenied)
        }
        XCTAssertEqual(server.authenticatedConnectionCount, 1)

        await server.stop()
    }

    // MARK: Trust surfacing

    func testConnectExecOnlySurfacesRequiresTrustAndTrustRetryEstablishes() async throws {
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        // NO pre-trust: host-key verification fails DURING the handshake,
        // before any channel — the typed .requiresTrust demand must
        // surface exactly as it does from connect(to:cols:rows:).
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: InMemoryPasswordStore(["pwd-tag": PasswordAuthTests.correctPassword])
        )
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let hostKeyBlob = try XCTUnwrap(Data(base64Encoded: String(components[1])))

        do {
            try await transport.connectExecOnly(to: makeConnection(port: port))
            XCTFail("an untrusted host key must surface .requiresTrust")
        } catch let error as SSHTransportError {
            guard case let .requiresTrust(_, algorithm, publicKeyData) = error else {
                XCTFail("expected .requiresTrust, got \(error)")
                return
            }
            XCTAssertEqual(algorithm, String(components[0]))
            XCTAssertEqual(publicKeyData, hostKeyBlob)
        }
        // Host-key verification precedes userauth: the server never saw a
        // completed authentication, and the transport tore the failed
        // connection down.
        XCTAssertEqual(server.authenticatedConnectionCount, 0)
        do {
            _ = try await transport.openExecChannel(command: "command -v herdr")
            XCTFail("exec after a failed establish must fail typed")
        } catch let error as TransportError {
            XCTAssertEqual(error, .channelDenied)
        }

        // The trust-retry shape the connector drives (handleTrustDemand):
        // trust the demanded key, re-establish — the channel-less
        // establish then succeeds on the same verifier.
        try await verifier.trust(
            host: "127.0.0.1", port: port, key: hostKeyBlob, algorithm: String(components[0])
        )
        try await transport.connectExecOnly(to: makeConnection(port: port))
        XCTAssertEqual(server.authenticatedConnectionCount, 1)

        await transport.close()
        await server.stop()
    }

    // MARK: Fixture helpers (the DebugPasswordServerFixtureTests patterns)

    private func makeTransport(
        for server: LoopbackPasswordSSHServer,
        port: Int
    ) async throws -> SSHTransport {
        SSHTransport(
            hostKeyVerifier: try await pretrustingVerifier(for: server, port: port),
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: InMemoryPasswordStore(["pwd-tag": PasswordAuthTests.correctPassword])
        )
    }

    private func makeConnection(port: Int) throws -> Connection {
        try Connection(
            name: "exec-only-fixture", type: .ssh, host: "127.0.0.1", port: port,
            username: Self.username, offersKeys: false, passwordTag: "pwd-tag"
        )
    }

    private func pretrustingVerifier(
        for server: LoopbackPasswordSSHServer,
        port: Int
    ) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(
            host: "127.0.0.1",
            port: port,
            key: blob,
            algorithm: String(components[0])
        )
        return verifier
    }

    /// Drains an exec stdout stream with a hard timeout, so a fixture bug
    /// fails the assertion instead of hanging the test.
    private func drainStdout(_ session: SSHExecSession) async -> String {
        let drained: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var data = Data()
                for await chunk in session.stdout {
                    data.append(chunk)
                }
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return drained ?? ""
    }
}
