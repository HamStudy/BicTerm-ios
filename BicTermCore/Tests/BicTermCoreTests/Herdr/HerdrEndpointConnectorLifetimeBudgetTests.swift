import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// Connection-per-consumer end-to-end proof against the CoderSSHGW
/// emulation fixture (`LoopbackPasswordSSHServer` with
/// `.lifetimeTotal(1)` — ONE session-channel open per connection
/// LIFETIME, the gateway's real budget): the connector's full flows must
/// consume exactly one session channel per connection (the consumer's
/// own exec) and exactly one connection per consumer.
///
/// Count invariants (via `authenticatedConnectionCount`): a compatible
/// `connect` = 2 connections (probe, bridge); an incompatible probe = 1
/// (the probe's, closed on every path — nothing keys a bridge off it); a
/// declined install offer = 1 (the probe's; no install, re-probe, or
/// bridge connection may follow a decline). The install-offering APPROVED
/// path is NOT tested against lifetime-1 here — the loopback server's
/// canned exec replies and closes immediately without draining stdin, so
/// the upload step cannot ride it. The installer resolves one FRESH
/// connection per exec step (prepare/upload/commit) from the injected
/// factory; its connection counts stay pinned in
/// `HerdrEndpointConnectorInstallTests` on the unlimited fixture.
final class HerdrEndpointConnectorLifetimeBudgetTests: XCTestCase {
    private static let username = "lifetime-user"

    /// Compatible probe output: recognized platform, a found binary, and
    /// a generation-1 client status (``HerdrProbe``'s `bpo:` line
    /// contract).
    private static let compatibleProbeResponse = """
        bpo:os=Darwin
        bpo:arch=arm64
        bpo:path=/home/lifetime-user/.local/bin/herdr
        bpo:status={"version":"0.9.0","endpoint_protocol_generation":1,"endpoint_capabilities":["surface_interest"]}

        """

    /// Present-but-incompatible: generation 99 fails the compatibility
    /// gate (and must never propose an install).
    private static let incompatibleProbeResponse = """
        bpo:os=Darwin
        bpo:arch=arm64
        bpo:path=/usr/local/bin/herdr
        bpo:status={"version":"0.8.0","endpoint_protocol_generation":99,"endpoint_capabilities":[]}

        """

    /// Missing binary on an otherwise-supported platform: the
    /// install-offering variants' trigger shape.
    private static let missingBinaryProbeResponse = """
        bpo:os=Darwin
        bpo:arch=arm64
        bpo:path=

        """

    // MARK: - Lifetime-budget count invariants

    func testConnectAgainstLifetimeBudgetOneSucceedsWithExactlyTwoConnections() async throws {
        let (key, acceptedBlob) = try makeClientKey()
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        server.execResponse = Self.compatibleProbeResponse

        let connector = try await makeConnector(key: key, server: server, port: port)
        let herdr = try await connector.connect(makeConnection(port: port))

        // Probe connection + bridge connection — one per consumer; the
        // bridge exec was the bridge connection's FIRST session channel
        // (budget slot #1), so it could only have opened on a FRESH
        // connection.
        XCTAssertEqual(server.authenticatedConnectionCount, 2)

        // Bridge round-trip: the bridge exec channel is open and the
        // canned response arrives with a clean exit.
        var received = Data()
        for try await chunk in herdr.inboundBytes() {
            received.append(chunk)
        }
        XCTAssertTrue(received.contains(Data("bpo:os=Darwin".utf8)))
        let termination = await herdr.session.termination()
        XCTAssertEqual(termination, .exited(status: 0))

        await herdr.close()
        await server.stop()
    }

    func testIncompatibleProbeAgainstLifetimeBudgetOneUsesExactlyOneConnection() async throws {
        let (key, acceptedBlob) = try makeClientKey()
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        server.execResponse = Self.incompatibleProbeResponse

        let connector = try await makeConnector(key: key, server: server, port: port)
        do {
            _ = try await connector.connect(makeConnection(port: port))
            XCTFail("a generation-99 endpoint must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertEqual(result.version, "0.8.0")
            XCTAssertEqual(result.endpointGeneration, 99)
            XCTAssertTrue(detail.contains("generation 99"), detail)
            XCTAssertTrue(detail.contains("requires generation 1"), detail)
        }

        // Exactly the probe's connection — closed on every probe path
        // (nothing keys a bridge connection off an incompatible result).
        XCTAssertEqual(server.authenticatedConnectionCount, 1)
        await server.stop()
    }

    func testDeclinedInstallOfferAgainstLifetimeBudgetOneUsesExactlyOneConnection() async throws {
        let (key, acceptedBlob) = try makeClientKey()
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        server.execResponse = Self.missingBinaryProbeResponse

        let provider = RecordingBinaryProvider()
        let connector = try await makeConnector(
            key: key,
            server: server,
            port: port,
            installer: HerdrRemoteInstaller(binaryProvider: provider),
            approveInstall: { _ in false }
        )
        do {
            _ = try await connector.connectOfferingInstall(makeConnection(port: port))
            XCTFail("a declined install must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(
                error,
                .installDeclined(HerdrInstallConsent(
                    host: "127.0.0.1",
                    target: .macosAarch64,
                    installDir: HerdrRemoteInstaller.defaultInstallDir
                ))
            )
        }

        // The probe's connection only: a decline opens no install,
        // re-probe, or bridge connection, and never fetches the binary.
        XCTAssertEqual(server.authenticatedConnectionCount, 1)
        XCTAssertTrue(provider.requestedTargets.isEmpty)
        await server.stop()
    }

    // MARK: - Fixture helpers

    /// Fresh software ed25519 key plus the blob the loopback server must
    /// accept for it.
    private func makeClientKey() throws -> (key: NIOSSHPrivateKey, acceptedBlob: Data) {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let components = String(openSSHPublicKey: key.publicKey)
            .split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            throw NSError(domain: "HerdrEndpointConnectorLifetimeBudgetTests", code: 1)
        }
        return (key, blob)
    }

    private func makeConnector(
        key: NIOSSHPrivateKey,
        server: LoopbackPasswordSSHServer,
        port: Int,
        installer: HerdrRemoteInstaller? = nil,
        approveInstall: (@Sendable (HerdrInstallConsent) async -> Bool)? = nil
    ) async throws -> HerdrEndpointConnector {
        HerdrEndpointConnector(
            hostKeyVerifier: try await pretrustingVerifier(for: server, port: port),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: ["/opt/homebrew/bin/herdr"],
            approveHostKey: { _ in false },
            installer: installer,
            approveInstall: approveInstall
        )
    }

    private func makeConnection(port: Int) throws -> Connection {
        try Connection(
            name: "lifetime-budget-fixture", type: .ssh, host: "127.0.0.1", port: port,
            username: Self.username, customKeys: ["fixture-ed25519"]
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

    /// Records calls and serves wrong bytes: the decline test asserts it
    /// was never asked for the binary.
    private final class RecordingBinaryProvider: HerdrBinaryProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [HerdrReleasePins.Target] = []

        func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
            lock.withLock { calls.append(target) }
            return Data("definitely not the pinned herdr binary".utf8)
        }

        var requestedTargets: [HerdrReleasePins.Target] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }
}
