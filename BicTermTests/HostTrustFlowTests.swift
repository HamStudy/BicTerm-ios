import BicTermCore
import XCTest
@testable import BicTerm

/// F1 TOFU trust-flow coverage: an unknown host surfaces its exact identity
/// for an explicit user decision; Trust persists via the production
/// verifier and retries; Cancel never trusts and never opens a shell;
/// changed host keys can never reach the trust action.
@MainActor
final class HostTrustFlowTests: XCTestCase {
    private typealias HostTrustChallenge = SessionStore.HostTrustChallenge

    private let unknownKeyBlob = Data([0x01, 0x02, 0x03, 0x04])
    private let otherKeyBlob = Data([0x09, 0x08, 0x07, 0x06])
    private let unknownFingerprint = "SHA256:unknown-host-fingerprint"

    private func makeConnection(name: String = "Alpha", host: String = "10.0.0.9", port: Int = 22) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: host,
            port: port,
            username: "unit",
            keyReference: "unit-key"
        )
    }

    private func makeStore(
        factory: ScriptedSessionTransportFactory,
        hostKeyStore: InMemoryHostKeyStoreFallback,
        connections: [Connection]
    ) -> SessionStore {
        let byID = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        return SessionStore(
            transportFactory: factory,
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { id in byID[id] },
            hostKeyVerifier: HostKeyVerifier(store: hostKeyStore),
            hostKeyStore: hostKeyStore
        )
    }

    private func seedFirstSeen(
        _ store: InMemoryHostKeyStoreFallback,
        host: String,
        port: Int,
        blob: Data,
        algorithm: String = "ssh-ed25519"
    ) throws {
        try store.saveSync(HostKeyRecord(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: blob,
            trustState: .firstSeen,
            firstSeenDate: Date()
        ))
    }

    private func record(
        in store: InMemoryHostKeyStoreFallback,
        host: String,
        port: Int
    ) async throws -> HostKeyRecord? {
        try await store.lookup(host: host, port: port)
    }

    private func waitForChallenge(
        _ model: SessionSceneModel,
        timeout: TimeInterval = 3
    ) async -> HostTrustChallenge? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let challenge = model.pendingTrustChallenge { return challenge }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model.pendingTrustChallenge
    }

    private func waitForNoChallenge(_ model: SessionSceneModel, settle: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitUntil(
        _ model: SessionSceneModel,
        timeout: TimeInterval = 5,
        matching predicate: (SessionState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.state) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(model.state)
    }

    /// The typed `.requiresTrust` failure presents host, port, algorithm,
    /// and fingerprint from the production verifier's first-seen record.
    func testUnknownHostSurfacesTrustChallengeWithExactIdentity() async throws {
        let factory = ScriptedSessionTransportFactory(
            queued: [.fail(.requiresTrust(fingerprint: unknownFingerprint, algorithm: "ssh-ed25519", publicKeyData: unknownKeyBlob))]
        )
        let hostKeys = InMemoryHostKeyStoreFallback()
        try seedFirstSeen(hostKeys, host: "10.0.0.9", port: 22, blob: unknownKeyBlob)
        let alpha = try makeConnection()
        let store = makeStore(factory: factory, hostKeyStore: hostKeys, connections: [alpha])

        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))
        await model.start()

        let failed = await waitUntil(model) {
            if case .failed(.transport(.requiresTrust)) = $0 { return true }
            return false
        }
        XCTAssertTrue(failed, "expected typed requiresTrust failure, got \(model.state)")

        let challenge = await waitForChallenge(model)
        XCTAssertNotNil(challenge, "failed trust verification must surface a challenge in the originating scene")
        XCTAssertEqual(challenge?.host, "10.0.0.9")
        XCTAssertEqual(challenge?.port, 22)
        XCTAssertEqual(challenge?.algorithm, "ssh-ed25519")
        XCTAssertEqual(challenge?.fingerprint, unknownFingerprint)
        XCTAssertTrue(model.isTrustPromptPresented)
        XCTAssertEqual(factory.createdCount, 1, "no retry may happen without the user's explicit Trust")
    }

    /// Cancel dismisses the prompt, persists nothing, retries nothing, and
    /// never produces a shell.
    func testCancelNeverTrustsAndNeverOpensShell() async throws {
        let factory = ScriptedSessionTransportFactory(
            queued: [.fail(.requiresTrust(fingerprint: unknownFingerprint, algorithm: "ssh-ed25519", publicKeyData: unknownKeyBlob))]
        )
        let hostKeys = InMemoryHostKeyStoreFallback()
        try seedFirstSeen(hostKeys, host: "10.0.0.9", port: 22, blob: unknownKeyBlob)
        let alpha = try makeConnection()
        let store = makeStore(factory: factory, hostKeyStore: hostKeys, connections: [alpha])

        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))
        await model.start()
        let challenge = await waitForChallenge(model)
        XCTAssertNotNil(challenge)

        model.cancelTrustPrompt()
        XCTAssertFalse(model.isTrustPromptPresented)
        await waitForNoChallenge(model)

        let record = try await record(in: hostKeys, host: "10.0.0.9", port: 22)
        XCTAssertEqual(record?.trustState, .firstSeen, "cancel must not persist trust")
        XCTAssertEqual(factory.createdCount, 1, "cancel must not trigger a retry")
        guard case .failed = model.state else {
            return XCTFail("cancel must leave the session failed, got \(model.state)")
        }
        XCTAssertTrue(model.tail.isEmpty, "no shell output may exist after cancel")
    }

    /// Trust persists through the production verifier and reconnects the
    /// same scene's session.
    func testTrustPersistsTrustAndReconnects() async throws {
        let factory = ScriptedSessionTransportFactory(queued: [
            .fail(.requiresTrust(fingerprint: unknownFingerprint, algorithm: "ssh-ed25519", publicKeyData: unknownKeyBlob)),
            .succeed,
        ])
        let hostKeys = InMemoryHostKeyStoreFallback()
        try seedFirstSeen(hostKeys, host: "10.0.0.9", port: 22, blob: unknownKeyBlob)
        let alpha = try makeConnection()
        let store = makeStore(factory: factory, hostKeyStore: hostKeys, connections: [alpha])

        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))
        await model.start()
        let optionalChallenge = await waitForChallenge(model)
        let challenge = try XCTUnwrap(optionalChallenge)

        await model.trustPendingHost()

        let record = try await record(in: hostKeys, host: challenge.host, port: challenge.port)
        XCTAssertEqual(record?.trustState, .trusted, "explicit Trust must persist through the verifier")

        let active = await waitUntil(model) { $0 == .active }
        XCTAssertTrue(active, "trusted host must reconnect after the explicit Trust action, got \(model.state)")
        XCTAssertEqual(factory.createdCount, 2, "exactly one safe retry after trusting")
    }

    /// A changed host key is a hard rejection: no trust challenge is ever
    /// presented for it.
    func testChangedHostKeyNeverOffersTrust() async throws {
        let factory = ScriptedSessionTransportFactory(
            queued: [.fail(.hostKeyChanged(host: "10.0.0.9", port: 22, oldFingerprint: "SHA256:old", newFingerprint: "SHA256:new"))]
        )
        let hostKeys = InMemoryHostKeyStoreFallback()
        let alpha = try makeConnection()
        let store = makeStore(factory: factory, hostKeyStore: hostKeys, connections: [alpha])

        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))
        await model.start()

        let rejected = await waitUntil(model) {
            if case .failed(.transport(.hostKeyChanged)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected, "expected typed hostKeyChanged failure, got \(model.state)")

        await waitForNoChallenge(model)
        XCTAssertNil(model.pendingTrustChallenge, "changed keys must never surface the trust prompt")
        XCTAssertFalse(model.isTrustPromptPresented)
    }

    /// Even a challenge whose key does not match the persisted record can
    /// not be trusted: the verifier's own changed-key guard rejects it and
    /// the failure surfaces without any retry.
    func testTrustActionOnMismatchedKeyIsRejectedByVerifier() async throws {
        let factory = ScriptedSessionTransportFactory(
            queued: [.fail(.requiresTrust(fingerprint: unknownFingerprint, algorithm: "ssh-ed25519", publicKeyData: unknownKeyBlob))]
        )
        let hostKeys = InMemoryHostKeyStoreFallback()
        // The (host, port) already TRUSTS a DIFFERENT key: offering the new
        // blob must hard-fail inside HostKeyVerifier.trust.
        try hostKeys.saveSync(HostKeyRecord(
            host: "10.0.0.9",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: otherKeyBlob,
            trustState: .trusted,
            firstSeenDate: Date()
        ))
        let alpha = try makeConnection()
        let store = makeStore(factory: factory, hostKeyStore: hostKeys, connections: [alpha])

        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))
        await model.start()
        let optionalChallenge = await waitForChallenge(model)
        let challenge = try XCTUnwrap(optionalChallenge)
        XCTAssertEqual(challenge.host, "10.0.0.9", "challenge resolves the persisted (host, port) for its key")

        await model.trustPendingHost()

        XCTAssertNotNil(model.trustErrorMessage, "verifier rejection must surface to the user")
        guard case .failed = model.state else {
            return XCTFail("mismatched trust must leave the session failed, got \(model.state)")
        }
        XCTAssertEqual(factory.createdCount, 1, "a rejected trust action must not retry")
        let record = try await record(in: hostKeys, host: "10.0.0.9", port: 22)
        XCTAssertEqual(record?.trustState, .trusted)
        XCTAssertEqual(record?.publicKeyData, otherKeyBlob, "the trusted key must be unchanged")
    }
}
