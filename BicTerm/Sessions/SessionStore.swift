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
    let passwordPresenter: PasswordPromptPresenter
    let agentBook: AgentSessionBook
    let hostKeyVerifier: HostKeyVerifier?
    /// Live terminal surfaces for every attached-or-detached session —
    /// the buffer-preservation layer behind the session switcher.
    let viewCache = TerminalViewCache()
    /// App-global terminal toolbar visibility preference (heuristic default
    /// from the hardware keyboard, sticky explicit choice). One instance
    /// shared by every scene so a toggle applies to all windows at once.
    let terminalToolbar = TerminalToolbarModel()
    /// App-global terminal font-size preference (default 14pt, persisted
    /// explicit choice, 9–32pt in 0.5 steps). One instance shared by every
    /// scene without an override follows Settings changes through the cache.
    let terminalFont = TerminalFontModel()
    /// App-global appearance preference (System default, persisted explicit
    /// Dark/Light choice). One instance shared by every scene: `BicTermApp`
    /// applies the color-scheme override at each WindowGroup root, so a
    /// Settings change re-themes every window at once.
    let theme = ThemeModel()
    let terminalMargin = TerminalMarginModel()
    var appearanceOverrides: [String: SessionAppearanceOverrides] = [:]

    private let hostKeyStore: (any HostKeyStoreProtocol)?
    private let connectionLookup: ConnectionLookup
    private let snapshotStore: (any SessionSnapshotStoreProtocol)?

    /// The backing key store this SessionStore's verifier reads and writes;
    /// the per-host forget action must clear trust through the same store,
    /// never a second instance.
    var activeHostKeyStore: (any HostKeyStoreProtocol)? { hostKeyStore }
    private var connectionNameCache: [UUID: String] = [:]
    private(set) var descriptors: [UUID: SessionDescriptor] = [:]
    private var orderedIDs: [UUID] = []
    private var sceneModels: [UUID: SessionSceneModel] = [:]

    /// iPad terminal-window → shown-session map, maintained live by
    /// `TerminalWindowRoot` as windows appear, switch content in place,
    /// and close (window close never closes the session — it detaches).
    /// The session menu's jump action reads this to FOCUS the window
    /// already hosting a picked session instead of attaching the same
    /// session in two windows at once.
    private(set) var windowSessionHosting: [UUID: UUID] = [:]
    private(set) var pendingWindowAttachments: [UUID: UUID] = [:]

    /// Live sessions in opening order — the switcher's stable listing.
    var orderedDescriptors: [SessionDescriptor] {
        orderedIDs.compactMap { descriptors[$0] }
    }

    func noteWindowHosting(windowValue: UUID, shows sessionID: UUID) {
        windowSessionHosting[windowValue] = sessionID
    }

    func noteWindowClosed(windowValue: UUID) {
        windowSessionHosting[windowValue] = nil
        pendingWindowAttachments[windowValue] = nil
    }

    /// The window value of the terminal window currently showing
    /// `sessionID`; nil when no window shows it (detached or iPhone cover).
    func hostingWindowValue(for sessionID: UUID) -> UUID? {
        windowSessionHosting.first(where: { $0.value == sessionID })?.key
    }

    func canReplaceSession(_ sessionID: UUID?) -> Bool {
        guard let sessionID, descriptors[sessionID] != nil else { return true }
        guard let model = existingModel(for: sessionID) else { return false }
        return model.canRetry || model.isClosed
    }

    /// Reserve a dead host before focusing its original window value. A pending
    /// attachment excludes that host from a second connection's selection.
    func requestDeadWindowAttachment(for sessionID: UUID) -> UUID? {
        let candidates = windowSessionHosting.filter {
            // An unresolved restored window is not a known dead session;
            // focusing it during restoration can leave prompts behind another scene.
            guard pendingWindowAttachments[$0.key] == nil,
                  let model = existingModel(for: $0.value) else { return false }
            return model.canRetry || model.isClosed
        }
        let window = candidates.sorted {
            let left = existingModel(for: $0.value)?.lastRetryableTransition ?? .distantPast
            let right = existingModel(for: $1.value)?.lastRetryableTransition ?? .distantPast
            return left == right ? $0.key.uuidString < $1.key.uuidString : left > right
        }.first?.key
        guard let window else { return nil }
        pendingWindowAttachments[window] = sessionID
        return window
    }

    func takeWindowAttachment(for windowValue: UUID) -> UUID? {
        pendingWindowAttachments.removeValue(forKey: windowValue)
    }

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
        let passwordPresenter = PasswordPromptPresenter(passwordStore: AppServices.shared.passwordStore)
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
                verifier: verifier,
                passwordPrompt: passwordPresenter
            )
        }

        self.registry = SessionRegistry(transportFactory: factory, snapshotStore: snapshots)
        self.agentPresenter = presenter
        self.passwordPresenter = passwordPresenter
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
        passwordPresenter.isSceneAvailable = { [weak self] sceneID in
            self?.descriptors.values.contains(where: { $0.registrySceneID == sceneID }) == true
        }

        // Resolve per scene even for detached surfaces; global changes must
        // not replace an explicit override or wait for a SwiftUI placement.
        viewCache.fontModel = terminalFont
        viewCache.resolveFontSize = { [weak self] sceneID in
            self?.effectiveFontSize(sceneID) ?? TerminalFontSettings.defaultSize
        }
        viewCache.onSceneFontPinch = { [weak self] sceneID, size in
            self?.setFontSize(size, sceneID: sceneID)
        }
        terminalFont.onApplied = { [weak self] _ in
            self?.refreshSceneFonts()
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
        orderedIDs.append(descriptor.id)
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
        orderedIDs.append(descriptor.id)
        connectionNameCache[connection.id] = connection.name
        return descriptor
    }

    func descriptor(id: UUID) -> SessionDescriptor? {
        descriptors[id]
    }

    /// Read-only model lookup (no side effects) — safe inside view bodies.
    func existingModel(for descriptorID: UUID) -> SessionSceneModel? {
        sceneModels[descriptorID]
    }

    /// Creates scene models for every live descriptor so the switcher's
    /// rows can render detached sessions that never had a view.
    func warmSceneModelsForSwitcher() {
        for id in orderedIDs where sceneModels[id] == nil {
            _ = sceneModel(for: id)
        }
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
        model.onReconnect = { [weak self] in
            self?.viewCache.resetSessionState(for: descriptorID)
        }
        return model
    }

    func closeScene(_ descriptorID: UUID) async {
        agentPresenter.denyPendingIfTargeting(scene: descriptorID)
        viewCache.removeSurface(for: descriptorID)
        if let descriptor = descriptors[descriptorID] {
            appearanceOverrides[descriptor.registrySceneID] = nil
            passwordPresenter.cancel(sceneID: descriptor.registrySceneID)
            await registry.closeSession(sceneID: descriptor.registrySceneID)
        }
        descriptors[descriptorID] = nil
        sceneModels[descriptorID] = nil
        orderedIDs.removeAll { $0 == descriptorID }
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

    /// Per-host forget (T20 security sweep): deletes the restorable session
    /// snapshots of every connection that resolves to `host:port`. Returns
    /// the number of snapshots removed; live scenes are untouched.
    func forgetRestorableSessions(host: String, port: Int) async -> Int {
        guard let snapshots = try? await registry.restorableSnapshots() else { return 0 }
        var removed = 0
        for snapshot in snapshots {
            guard let connection = await connectionLookup(snapshot.connectionID),
                  connection.host == host, connection.port == port
            else { continue }
            try? await snapshotStore?.deleteSnapshot(sceneID: snapshot.sceneID)
            removed += 1
        }
        return removed
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
        verifier: HostKeyVerifier,
        passwordPrompt: any SSHPasswordPrompting
    ) -> any TerminalTransportFactory {
        var registry = TransportRegistry()
        registry.register(.ssh, factory: SSHSessionTransportFactory(
            hostKeyVerifier: verifier, passwordStore: AppServices.shared.passwordStore,
            passwordPrompt: passwordPrompt
        ))
        return AgentForwardingTransportFactory(
            base: registry,
            keyProvider: DefaultAgentKeyProvider(),
            authorizer: authorizer,
            book: book,
            agentForwardingApplies: { $0.type == .ssh }
        )
    }

    static func defaultHostKeyStoreForLiveUse() -> any HostKeyStoreProtocol {
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

        func forget(host: String, port: Int) {
            lock.lock()
            defer { lock.unlock() }
            records["\(host):\(port)"] = nil
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

    func forget(host: String, port: Int) async throws(PersistenceError) {
        storage.forget(host: host, port: port)
    }

    /// Synchronous save for the DEBUG pre-trust seeding path.
    func saveSync(_ record: HostKeyRecord) {
        storage.save(record)
    }
}
