import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import BicTermCore

/// Trust-model isolation tests for Coder workspace sessions (spec §10.5/§11.2):
/// `.coderTunnelTrust` accepts any agent host key unconditionally because the
/// authenticated tailnet transport is the authorization boundary, and this
/// policy is enum-separated from TOFU so ordinary SSH profiles can never pick
/// it up.
final class CoderTrustPolicyTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private func keyBlob(_ seed: String) -> Data {
        Data(SHA256.hash(data: Data(seed.utf8)))
    }

    // MARK: - Mode construction

    func testFactoryDefaultsToTOFUAndCoderFactoryIsSeparateMode() throws {
        let tofu = HostKeyVerifier(store: EphemeralHostKeyStore())
        let coder = HostKeyVerifier.coderTunnel()

        XCTAssertEqual(tofu.trustPolicy, .tofu)
        XCTAssertEqual(coder.trustPolicy, .coderTunnelTrust)
        XCTAssertNotEqual(HostKeyVerifier.TrustPolicy.tofu, .coderTunnelTrust)
    }

    // MARK: - Coder-tunnel verify semantics

    func testCoderTunnelTrustAcceptsUnseenKeyWithoutPersisting() async throws {
        // Given: a shared store and a coder-tunnel verifier over it
        let store = EphemeralHostKeyStore()
        let verifier = HostKeyVerifier(store: store, trustPolicy: .coderTunnelTrust)

        // When: an unseen key is presented
        let verdict = try await verifier.verify(
            host: "workspace.coder",
            port: 1,
            key: keyBlob("agent-key-a"),
            algorithm: "ssh-ed25519"
        )

        // Then: trusted unconditionally, and nothing lands in the store
        XCTAssertEqual(verdict, .trusted)
        let record = try await store.lookup(host: "workspace.coder", port: 1)
        XCTAssertNil(record, "coder-tunnel accepts must never persist host keys")
    }

    func testCoderTunnelTrustAcceptsChangedKeyUnconditionally() async throws {
        // Given: an agent whose host key rotates between rebuilds
        let verifier = HostKeyVerifier.coderTunnel()

        // When: two different keys arrive on the same identity
        let first = try await verifier.verify(
            host: "workspace.coder",
            port: 1,
            key: keyBlob("agent-key-a"),
            algorithm: "ssh-ed25519"
        )
        let second = try await verifier.verify(
            host: "workspace.coder",
            port: 1,
            key: keyBlob("agent-key-b"),
            algorithm: "ssh-ed25519"
        )

        // Then: both accepted — key ROTATION IS EXPECTED (ephemeral agent keys)
        XCTAssertEqual(first, .trusted)
        XCTAssertEqual(second, .trusted)
    }

    func testCoderTunnelTrustIgnoresExistingStoreRecords() async throws {
        // Given: a store holding a TOFU-trusted record for the identity
        let store = EphemeralHostKeyStore()
        let tofu = HostKeyVerifier(store: store, trustPolicy: .tofu)
        try await tofu.trust(
            host: "shared.example",
            port: 22,
            key: keyBlob("stored-key"),
            algorithm: "ssh-ed25519"
        )
        let coder = HostKeyVerifier(store: store, trustPolicy: .coderTunnelTrust)

        // When: a coder-tunnel verify presents a DIFFERENT key
        let verdict = try await coder.verify(
            host: "shared.example",
            port: 22,
            key: keyBlob("unrelated-agent-key"),
            algorithm: "ssh-ed25519"
        )

        // Then: still trusted — coder mode never consults store contents
        XCTAssertEqual(verdict, .trusted)
    }

    func testTrustCallIsNoOpInCoderTunnelMode() async throws {
        // Given: a shared store and a coder-tunnel verifier
        let store = EphemeralHostKeyStore()
        let coder = HostKeyVerifier(store: store, trustPolicy: .coderTunnelTrust)

        // When: trust() is invoked (UI prompt plumbing reaching it in error)
        try await coder.trust(
            host: "workspace.coder",
            port: 1,
            key: keyBlob("agent-key-a"),
            algorithm: "ssh-ed25519"
        )

        // Then: nothing was written
        let records = try await store.loadAll()
        XCTAssertTrue(records.isEmpty, "coder-tunnel trust() must stay persistence-free")
    }

    // MARK: - Isolation of the TOFU side

    func testTofuPerspectiveOnCoderAcceptedIdentityStillRequiresTrust() async throws {
        // Given: coder-tunnel accepted a key on a shared store
        let store = EphemeralHostKeyStore()
        let coder = HostKeyVerifier(store: store, trustPolicy: .coderTunnelTrust)
        _ = try await coder.verify(
            host: "boundary.example",
            port: 1,
            key: keyBlob("agent-key-a"),
            algorithm: "ssh-ed25519"
        )

        // When: the same identity is queried through a TOFU verifier
        let tofu = HostKeyVerifier(store: store)
        let verdict = try await tofu.verify(
            host: "boundary.example",
            port: 1,
            key: keyBlob("agent-key-a"),
            algorithm: "ssh-ed25519"
        )

        // Then: TOFU still demands an explicit trust decision
        guard case .requiresTrust = verdict else {
            return XCTFail("TOFU must not observe coder-tunnel acceptances, got \(verdict)")
        }
    }

    // MARK: - NoClientAuth delegate offer semantics

    func testNoClientAuthDelegateOffersNoneExactlyOnceThenFailsTyped() async throws {
        let loop = EmbeddedEventLoop()
        let delegate = NoClientUserAuthenticationDelegate(username: "coder")

        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
        let offer = try await first.futureResult.get()

        let unwrapped = try XCTUnwrap(offer)
        XCTAssertEqual(unwrapped.username, "coder")
        guard case NIOSSHUserAuthenticationOffer.Offer.none = unwrapped.offer else {
            return XCTFail("expected a none offer, got \(unwrapped.offer)")
        }

        // A server that rejects `none` re-asks; coder mode never falls back to
        // credentials — the typed authentication failure is the only answer.
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
        await assertThrowsSSHError(.authenticationFailed) {
            _ = try await second.futureResult.get()
        }
    }

    // MARK: - End-to-end composition over UDS

    private func beginCollecting(_ transport: SSHTransport) async -> SSHOutputSink {
        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        return sink
    }

    func testCoderTunnelSessionComposesOverUDSWithoutTrustInteraction() async throws {
        // Given: a NoClientAuth server presenting an ephemeral unseen host key
        let path = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/coder-ssh-\(UUID().uuidString).sock")
            .path
        let server = LoopbackNoAuthSSHUDSServer(path: path)
        try await server.start()
        defer { Task { await server.stop() } }

        // When: a coder-tunnel transport dials it over UDS
        let transport = SSHTransport(hostKeyVerifier: .coderTunnel())
        defer { Task { await transport.close() } }
        try await transport.connect(unixSocketPath: path, cols: 80, rows: 24)
        let sink = await beginCollecting(transport)

        // Then: the session opens with no trust prompt and no prompt plumbing
        let greeted = await waitForContent(
            sink: sink,
            marker: LoopbackNoAuthSSHUDSServer.greeting,
            timeoutMilliseconds: 15000
        )
        XCTAssertTrue(greeted)
        await transport.close()
        await server.stop()
    }

    func testTofuVerifierStillGatesAnUnseenCoderServerHostKey() async throws {
        // Given: a TOFU-mode transport meeting the coder-posture server
        let path = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/coder-ssh-\(UUID().uuidString).sock")
            .path
        let server = LoopbackNoAuthSSHUDSServer(path: path)
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = SSHTransport(hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()))
        defer { Task { await transport.close() } }

        // When/Then: the unseen host key surfaces the typed trust gate —
        // UDS + NoClientAuth never smuggles a server past TOFU
        do {
            try await transport.connect(unixSocketPath: path, cols: 80, rows: 24)
            XCTFail("TOFU must gate an unseen coder host key")
        } catch let error as TransportError {
            guard case .requiresTrust = error else {
                return XCTFail("expected .requiresTrust, got \(error)")
            }
        }
        await transport.close()
        await server.stop()
    }

    func testCoderTunnelSessionAgainstCredentialRequiringServerFailsTyped() async throws {
        // Given: the fixtures-up forwarder at a real credential-requiring sshd
        let fixtureUDS = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/sshd-uds.sock")
            .path
        guard FileManager.default.fileExists(atPath: fixtureUDS) else {
            throw XCTSkip("fixtures-up.sh not running (no sshd-uds.sock)")
        }

        // When: a coder-tunnel transport dials it — host key is accepted, then
        // the agent posture offers `none` auth
        let transport = SSHTransport(hostKeyVerifier: .coderTunnel())
        defer { Task { await transport.close() } }

        // Then: the sshd rejects `none`; the failure is typed and final
        await assertThrowsSSHError(.authenticationFailed) {
            try await transport.connect(unixSocketPath: fixtureUDS, cols: 80, rows: 24)
        }
    }

    // MARK: - Static separation guard

    /// The normal SSH profile factory must never reach for coder-tunnel
    /// trust or the NoClientAuth delegate. Pinned as source structure (symbol
    /// names), which `SSHTransportStaticGuardTests` precedent relies on.
    func testNormalSSHFactoryNeverReferencesCoderTrustMachinery() throws {
        let factorySource = try String(
            contentsOf: SSHTestFixture.repoRoot.appendingPathComponent(
                "BicTermCore/Sources/BicTermCore/SSH/SSHTerminalTransportFactory.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(
            factorySource.contains("coderTunnel"),
            "normal SSH profile factory must not construct the coder trust policy"
        )
        XCTAssertFalse(
            factorySource.contains("NoClientUserAuthenticationDelegate"),
            "normal SSH profile factory must not select NoClientAuth"
        )

        // Non-vacuous: the separation pins above only mean something while the
        // coder machinery exists at its designated home.
        let verifierSource = try String(
            contentsOf: SSHTestFixture.repoRoot.appendingPathComponent(
                "BicTermCore/Sources/BicTermCore/Trust/HostKeyVerifier.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(verifierSource.contains("coderTunnelTrust"))
        let bridgeSource = try String(
            contentsOf: SSHTestFixture.repoRoot.appendingPathComponent(
                "BicTermCore/Sources/BicTermCore/SSH/SSHNIOBridge.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(bridgeSource.contains("NoClientUserAuthenticationDelegate"))
    }
}
