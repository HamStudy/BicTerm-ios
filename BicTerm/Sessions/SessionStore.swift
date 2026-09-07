import BicTermCore
import Foundation
import SwiftUI
import UIKit

/// One terminal scene's binding to the T10 registry: the window value plus
/// the connection it owns. `restoredSceneID` is non-nil when this scene was
/// opened from a termination snapshot — the registry session then keeps the
/// SNAPSHOT's original scene ID so a successful reconnect deletes exactly
/// that snapshot, and a second window can never attach to the same session
/// (the store returns the existing descriptor and the registry's
/// `sceneOccupied` guard backstops it).
@MainActor
@Observable
final class SessionStore {
    struct SessionDescriptor: Identifiable, Sendable {
        let id: UUID
        let connection: Connection
        let restoredSceneID: String?
        /// True when the user opened this scene THROUGH the restorable
        /// list's Reconnect button — that tap is the manual reconnect
        /// action, so the scene restores AND reconnects. Scenes opened by
        /// any other path restore to `.reconnectRequired` only.
        let initiatesReconnect: Bool

        var isRestored: Bool { restoredSceneID != nil }
        var registrySceneID: String { restoredSceneID ?? "scene-\(id.uuidString)" }
    }

    /// A termination snapshot plus the resolved connection it can restore.
    struct RestorableSession: Identifiable, Sendable {
        let snapshot: SessionSnapshot
        let connection: Connection

        var id: String { snapshot.sceneID }
    }

    /// Everything the TOFU trust prompt shows and the trust action needs:
    /// identity from the typed `.requiresTrust` payload, with (host, port)
    /// resolved from the verifier's own first-seen record for that exact
    /// key blob (correct for jump-chain hops too, where the failure does
    /// not name its hop). Never carries secret material — public key only.
    struct HostTrustChallenge: Identifiable, Equatable, Sendable {
        let host: String
        let port: Int
        let algorithm: String
        let fingerprint: String
        let publicKeyData: Data

        var id: String { "\(host):\(port)-\(fingerprint)" }
    }

    typealias ConnectionLookup = @Sendable (UUID) async -> Connection?

    let registry: SessionRegistry
    let agentPresenter: AgentApprovalPresenter
    let agentBook: AgentSessionBook
    let hostKeyVerifier: HostKeyVerifier?

    private let hostKeyStore: (any HostKeyStoreProtocol)?
    private let connectionLookup: ConnectionLookup
    private let snapshotStore: (any SessionSnapshotStoreProtocol)?
    private var connectionNameCache: [UUID: String] = [:]
    private(set) var descriptors: [UUID: SessionDescriptor] = [:]
    private var sceneModels: [UUID: SessionSceneModel] = [:]

    /// Production wiring: real SSH factory (agent-forwarding enabled) and
    /// the SwiftData session-snapshot store. Tests inject a fake transport
    /// factory and an in-memory snapshot store instead.
    init(
        transportFactory: (any TerminalTransportFactory)? = nil,
        snapshotStore: (any SessionSnapshotStoreProtocol)? = nil,
        connectionLookup: ConnectionLookup? = nil,
        hostKeyVerifier injectedVerifier: HostKeyVerifier? = nil,
        hostKeyStore injectedHostKeyStore: (any HostKeyStoreProtocol)? = nil
    ) {
        let snapshots = snapshotStore ?? Self.defaultSnapshotStore()
        let book = AgentSessionBook()
        let presenter = AgentApprovalPresenter(resolveRouting: { _ in
            AgentPromptRouting(target: .mainWindow, sessionDisplayName: "Session")
        })
        let authorizer = AgentAuthorizationService(
            prompt: presenter,
            lockState: ApplicationLockStateProvider()
        )

        let verifier: HostKeyVerifier
        let keyStore: any HostKeyStoreProtocol
        if let injectedVerifier {
            verifier = injectedVerifier
            keyStore = injectedHostKeyStore ?? InMemoryHostKeyStoreFallback()
        } else {
            keyStore = Self.defaultHostKeyStoreForLiveUse()
            verifier = HostKeyVerifier(store: keyStore)
        }

        let factory: any TerminalTransportFactory
        if let transportFactory {
            // Tests route prompts through the same book/presenter path.
            factory = AgentForwardingTransportFactory(
                base: transportFactory,
                keyProvider: DefaultAgentKeyProvider(),
                authorizer: authorizer,
                book: book,
                agentForwardingApplies: { _ in true }
            )
        } else {
            factory = Self.makeLiveFactory(
                authorizer: authorizer,
                book: book,
                verifier: verifier
            )
        }

        self.registry = SessionRegistry(transportFactory: factory, snapshotStore: snapshots)
        self.agentPresenter = presenter
        self.agentBook = book
        self.hostKeyVerifier = verifier
        self.hostKeyStore = injectedHostKeyStore ?? keyStore
        self.snapshotStore = snapshotStore

        if let connectionLookup {
            self.connectionLookup = connectionLookup
        } else {
            let store = AppServices.shared.connectionStore
            self.connectionLookup = { id in (try? await store.connection(id: id)) ?? nil }
        }

        presenter.configureRouting { [weak self] bridgeSessionID in
            guard let self else {
                return AgentPromptRouting(target: .mainWindow, sessionDisplayName: "Session")
            }
            guard let connectionID = self.agentBook.connectionID(for: bridgeSessionID) else {
                return AgentPromptRouting(target: .mainWindow, sessionDisplayName: "Session")
            }
            if let descriptor = self.descriptors.values.first(where: { $0.connection.id == connectionID }) {
                return AgentPromptRouting(target: .scene(descriptor.id), sessionDisplayName: descriptor.connection.name)
            }
            if let name = self.connectionNameCache[connectionID] {
                return AgentPromptRouting(target: .mainWindow, sessionDisplayName: name)
            }
            return AgentPromptRouting(target: .mainWindow, sessionDisplayName: "Session")
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.registry.willTerminate()
            }
        }
    }

    // MARK: - Opening scenes

    @discardableResult
    func openSession(for connection: Connection) -> SessionDescriptor {
        let descriptor = SessionDescriptor(
            id: UUID(),
            connection: connection,
            restoredSceneID: nil,
            initiatesReconnect: false
        )
        descriptors[descriptor.id] = descriptor
        connectionNameCache[connection.id] = connection.name
        return descriptor
    }

    /// Opening the same snapshot twice focuses the ALREADY-OPEN scene: one
    /// registry session (and one transport) per snapshot, ever.
    @discardableResult
    func openRestoredSession(
        snapshot: SessionSnapshot,
        connection: Connection,
        initiatesReconnect: Bool = false
    ) -> SessionDescriptor {
        if let existing = descriptors.values.first(where: { $0.restoredSceneID == snapshot.sceneID }) {
            return existing
        }
        let descriptor = SessionDescriptor(
            id: UUID(),
            connection: connection,
            restoredSceneID: snapshot.sceneID,
            initiatesReconnect: initiatesReconnect
        )
        descriptors[descriptor.id] = descriptor
        connectionNameCache[connection.id] = connection.name
        return descriptor
    }

    func descriptor(id: UUID) -> SessionDescriptor? {
        descriptors[id]
    }

    func sceneModel(for descriptorID: UUID) -> SessionSceneModel? {
        if let model = sceneModels[descriptorID] {
            return model
        }
        guard let descriptor = descriptors[descriptorID] else { return nil }
        let model = SessionSceneModel(
            descriptor: descriptor,
            registry: registry,
            onClose: { [weak self] id in
                await self?.closeScene(id)
            },
            trustStore: self
        )
        sceneModels[descriptorID] = model
        return model
    }

    func closeScene(_ descriptorID: UUID) async {
        agentPresenter.denyPendingIfTargeting(scene: descriptorID)
        if let descriptor = descriptors[descriptorID] {
            await registry.closeSession(sceneID: descriptor.registrySceneID)
        }
        descriptors[descriptorID] = nil
        sceneModels[descriptorID] = nil
    }

    // MARK: - Restoration listing

    /// Snapshots restorable in this launch: their connection still exists
    /// and no scene has opened them yet. Each restores as
    /// `.reconnectRequired` — reconnection is always a manual action.
    func loadRestorableSessions() async -> [RestorableSession] {
        guard let snapshots = try? await registry.restorableSnapshots() else { return [] }
        var result: [RestorableSession] = []
        for snapshot in snapshots {
            guard !descriptors.values.contains(where: { $0.restoredSceneID == snapshot.sceneID }) else {
                continue
            }
            guard let connection = await connectionLookup(snapshot.connectionID) else { continue }
            connectionNameCache[connection.id] = connection.name
            result.append(RestorableSession(snapshot: snapshot, connection: connection))
        }
        return result.sorted { $0.snapshot.createdAt < $1.snapshot.createdAt }
    }

    // MARK: - Window restoration

    /// Resolves a state-restored terminal window whose SessionID has no
    /// live descriptor against the T2 snapshot store: fresh sessions use
    /// `scene-<uuid>` registry scene IDs matching the window value, so a
    /// termination snapshot revives the window as a reconnect-required
    /// scene (never auto-connecting). Returns without effect when no
    /// snapshot/connection exists — the window keeps its placeholder.
    func resolveRestoredWindow(sessionID: UUID) async {
        #if DEBUG
        // UI tests clear snapshots at launch (except the restore test);
        // while that clear is pending, restored windows must stay inert so
        // exactly one live scene exists per connection under test.
        if TerminalSceneUITest.seamsEnabled,
           !ProcessInfo.processInfo.arguments.contains("--uitest-expect-restore") {
            return
        }
        #endif

        guard descriptors[sessionID] == nil else { return }
        let sceneID = "scene-\(sessionID.uuidString)"
        guard let snapshotStore else { return }
        let snapshot: SessionSnapshot
        do {
            guard let stored = try await snapshotStore.snapshot(sceneID: sceneID) else { return }
            snapshot = stored
        } catch {
            return
        }
        guard let connection = await connectionLookup(snapshot.connectionID) else { return }
        _ = openRestoredSession(snapshot: snapshot, connection: connection)
    }

    // MARK: - Host-key trust (TOFU)

    /// Builds the trust challenge for a typed `.requiresTrust` payload.
    /// (host, port) come from the verifier's persisted first-seen record
    /// whose key blob matches EXACTLY — the record the failing
    /// verification just wrote — falling back to the connection's own
    /// endpoint for direct connections. Only `.requiresTrust` payloads may
    /// pass through here; changed keys never call this path.
    func resolveHostTrustChallenge(
        fingerprint: String,
        algorithm: String,
        publicKeyData: Data,
        connection: Connection
    ) async -> HostTrustChallenge? {
        let records = (try? await hostKeyStore?.loadAll()) ?? nil ?? []
        let match = records.first {
            $0.publicKeyData == publicKeyData && $0.trustState == .firstSeen
        }
        let host = match?.host ?? connection.host
        let port = match?.port ?? connection.port
        return HostTrustChallenge(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
            publicKeyData: publicKeyData
        )
    }

    /// The explicit user Trust action: persists through the production
    /// `HostKeyVerifier.trust` path (which itself hard-rejects a key that
    /// mismatches the stored record) and reports the typed outcome.
    func trustHost(
        _ challenge: HostTrustChallenge
    ) async -> Result<Void, HostKeyTrustError> {
        guard let hostKeyVerifier else {
            return .failure(.persistence(.operationFailed("no host key verifier is configured")))
        }
        do {
            try await hostKeyVerifier.trust(
                host: challenge.host,
                port: challenge.port,
                key: challenge.publicKeyData,
                algorithm: challenge.algorithm
            )
            return .success(())
        } catch let error as HostKeyTrustError {
            return .failure(error)
        } catch {
            return .failure(.persistence(.operationFailed("trust failed")))
        }
    }

    // MARK: - Production wiring helpers

    private static func makeLiveFactory(
        authorizer: AgentAuthorizationService,
        book: AgentSessionBook,
        verifier: HostKeyVerifier
    ) -> any TerminalTransportFactory {
        let base = SSHSessionTransportFactory(hostKeyVerifier: verifier)
        return AgentForwardingTransportFactory(
            base: base,
            keyProvider: DefaultAgentKeyProvider(),
            authorizer: authorizer,
            book: book,
            agentForwardingApplies: { $0.type == .ssh }
        )
    }

    private static func defaultHostKeyStoreForLiveUse() -> any HostKeyStoreProtocol {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-pretrust-fixtures") {
            // UITEST hook: trust the committed loopback fixture host keys in
            // memory so connection flows can skip the trust prompt. Release
            // builds never take it.
            return preTrustedFixtureHostKeyStore()
        }
        #endif
        return defaultHostKeyStore()
    }

    private static func defaultSnapshotStore() -> any SessionSnapshotStoreProtocol {
        (try? PersistenceStoreFactory.makeSessionSnapshotStore())
            ?? InMemorySnapshotStoreFallback()
    }

    private static func defaultHostKeyStore() -> any HostKeyStoreProtocol {
        (try? PersistenceStoreFactory.makeHostKeyStore())
            ?? InMemoryHostKeyStoreFallback()
    }

    #if DEBUG
    private static func preTrustedFixtureHostKeyStore() -> InMemoryHostKeyStoreFallback {
        let store = InMemoryHostKeyStoreFallback()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for (port, keyFile) in [(12222, "hop1_host_ed25519.pub"), (12223, "hop2_host_ed25519.pub")] {
            let url = root.appendingPathComponent("Fixtures/sshd/host_keys/\(keyFile)")
            guard let line = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { continue }
            try? store.saveSync(HostKeyRecord(
                host: "127.0.0.1",
                port: port,
                algorithm: String(parts[0]),
                publicKeyData: blob,
                trustState: .trusted,
                firstSeenDate: Date()
            ))
        }
        return store
    }

    /// UITEST driver support.
    func clearSnapshotsForUITests() async {
        guard let snapshots = try? await registry.restorableSnapshots() else { return }
        for snapshot in snapshots {
            try? await snapshotStore?.deleteSnapshot(sceneID: snapshot.sceneID)
        }
    }

    func waitUntilActive(_ descriptorID: UUID, timeout: TimeInterval) async -> Bool {
        guard let descriptor = descriptors[descriptorID] else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = await registry.state(sceneID: descriptor.registrySceneID), state == .active {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    #endif
}

// MARK: - In-memory fallbacks

/// Last-resort snapshot persistence when SwiftData cannot initialize.
private actor InMemorySnapshotStoreFallback: SessionSnapshotStoreProtocol {
    private var snapshots: [String: SessionSnapshot] = [:]

    func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot] {
        Array(snapshots.values)
    }

    func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot? {
        snapshots[sceneID]
    }

    func save(_ snapshot: SessionSnapshot) async throws(PersistenceError) {
        snapshots[snapshot.sceneID] = snapshot
    }

    func deleteSnapshot(sceneID: String) async throws(PersistenceError) {
        snapshots[sceneID] = nil
    }
}

/// Last-resort host-key persistence when SwiftData cannot initialize, and
/// DEBUG UITEST pre-trust target for the fixture sshd host keys.
final class InMemoryHostKeyStoreFallback: HostKeyStoreProtocol, @unchecked Sendable {
    private let storage = Storage()

    private final class Storage {
        private let lock = NSLock()
        private var records: [String: HostKeyRecord] = [:]

        func loadAll() -> [HostKeyRecord] {
            lock.lock()
            defer { lock.unlock() }
            return Array(records.values)
        }

        func lookup(host: String, port: Int) -> HostKeyRecord? {
            lock.lock()
            defer { lock.unlock() }
            return records["\(host):\(port)"]
        }

        func save(_ record: HostKeyRecord) {
            lock.lock()
            defer { lock.unlock() }
            records["\(record.host):\(record.port)"] = record
        }
    }

    func loadAll() async throws(PersistenceError) -> [HostKeyRecord] {
        storage.loadAll()
    }

    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord? {
        storage.lookup(host: host, port: port)
    }

    func save(_ record: HostKeyRecord) async throws(PersistenceError) {
        storage.save(record)
    }

    /// Synchronous save for the DEBUG pre-trust seeding path.
    func saveSync(_ record: HostKeyRecord) {
        storage.save(record)
    }
}
