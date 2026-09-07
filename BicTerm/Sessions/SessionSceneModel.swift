import BicTermCore
import Foundation
import SwiftUI

/// Per-scene binding between one terminal window (or iPhone cover) and its
/// single registry session: state observation, terminal I/O forwarding, the
/// manual-reconnect action, close confirmation, and scene-phase wiring.
///
/// Restoration rule: a scene opened from a termination snapshot starts
/// `.suspended` and NEVER auto-connects — background→foreground cycles are
/// ignored until the user has acted (connect/reconnect) in this scene.
@MainActor
@Observable
final class SessionSceneModel: Identifiable {
    let id: UUID
    let sceneID: String
    let connectionName: String
    let registry: SessionRegistry
    let descriptor: SessionStore.SessionDescriptor

    private let onClose: @MainActor (UUID) async -> Void
    private weak var trustStore: SessionStore?

    private(set) var state: SessionState
    private(set) var launchErrorMessage: String?
    private(set) var pendingCloseConfirmation = false
    private(set) var isClosed = false
    private(set) var tail = ""
    private(set) var pendingTrustChallenge: SessionStore.HostTrustChallenge?
    private(set) var trustErrorMessage: String?

    let viewOutput: AsyncStream<Data>
    private let viewOutputContinuation: AsyncStream<Data>.Continuation

    private var stateTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var disappearCloseTask: Task<Void, Never>?
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []
    private var started = false
    private var didUserConnect = false
    private var trustPromptDismissed = false
    private var lastTrustChallengeKey: Data?
    private var previousTrustState: SessionState?

    init(
        descriptor: SessionStore.SessionDescriptor,
        registry: SessionRegistry,
        onClose: @escaping @MainActor (UUID) async -> Void,
        trustStore: SessionStore? = nil
    ) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.sceneID = descriptor.registrySceneID
        self.connectionName = descriptor.connection.name
        self.registry = registry
        self.onClose = onClose
        self.trustStore = trustStore
        self.state = descriptor.isRestored ? .suspended : .connecting
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.viewOutput = stream
        self.viewOutputContinuation = continuation

        // Suspend/resume follows APPLICATION-level lifecycle, not per-scene
        // scenePhase: on iPad a window merely COVERED by a sibling window
        // reports .background, and its session must stay live.
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.scenePhaseChanged(.background)
                }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.scenePhaseChanged(.active)
                }
            },
        ]
    }

    deinit {
        let observers = lifecycleObservers
        NotificationCenter.default.removeObserver(observers)
    }

    var connection: Connection { descriptor.connection }
    var protocolID: String { descriptor.connection.type.rawValue }

    var statusText: String {
        switch state {
        case .connecting: "Connecting…"
        case .active: "Connected"
        case .disconnected: "Disconnected"
        case .reconnecting: "Reconnecting…"
        case .suspended: "Reconnect required"
        case .failed(let failure): "Failed: \(failure.localizedDescription)"
        case .closed: "Session ended"
        }
    }

    var failureMessage: String? {
        if case .failed(let failure) = state {
            return failure.localizedDescription
        }
        return launchErrorMessage
    }

    var canRetry: Bool {
        switch state {
        case .disconnected, .suspended, .failed: !isClosed
        case .connecting, .active, .reconnecting, .closed: false
        }
    }

    var requiresCloseConfirmation: Bool {
        switch state {
        case .connecting, .active, .reconnecting: true
        case .disconnected, .suspended, .failed, .closed: false
        }
    }

    var isTerminalVisible: Bool {
        !isClosed
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started, !isClosed else { return }
        started = true
        do {
            if descriptor.isRestored {
                try await registry.restore(sceneID: sceneID, connection: descriptor.connection)
            } else {
                didUserConnect = true
                try await registry.startSession(sceneID: sceneID, connection: descriptor.connection)
            }
        } catch {
            launchErrorMessage = (error as? SessionRegistryError)?.localizedDescription
                ?? String(describing: error)
        }
        attachStreams()
        if descriptor.initiatesReconnect {
            await reconnect()
        }
    }

    private func attachStreams() {
        stateTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.registry.states(sceneID: self.sceneID) else { return }
            for await newState in stream {
                self.state = newState
                self.updateTrustChallenge(for: newState)
            }
        }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.registry.output(sceneID: self.sceneID) else { return }
            var tailBytes = Data()
            for await chunk in stream {
                self.viewOutputContinuation.yield(chunk)
                tailBytes.append(chunk)
                if tailBytes.count > 8_192 {
                    tailBytes.removeFirst(tailBytes.count - 8_192)
                }
                self.tail = String(decoding: tailBytes, as: UTF8.self)
            }
        }
    }

    /// Manual reconnect (user action). Marks the scene user-connected, which
    /// re-enables normal background/foreground reconnect behavior.
    func reconnect() async {
        guard !isClosed else { return }
        didUserConnect = true
        launchErrorMessage = nil
        _ = try? await registry.reconnect(sceneID: sceneID)
    }

    func scenePhaseChanged(_ phase: ScenePhase) async {
        guard !isClosed else { return }
        switch phase {
        case .background:
            await registry.didEnterBackground(sceneID: sceneID)
        case .active:
            guard didUserConnect else { return }
            await registry.willEnterForeground(sceneID: sceneID)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Host-key trust (TOFU)

    var isTrustPromptPresented: Bool {
        pendingTrustChallenge != nil && !trustPromptDismissed
    }

    /// Only the typed `.requiresTrust` failure produces a challenge — and
    /// only when it is a FRESH failure (a state transition into
    /// trust-required, or a different key), so a dismissed prompt stays
    /// dismissed until the user retries. Changed keys never enter this
    /// path; every other state clears the challenge.
    private func updateTrustChallenge(for newState: SessionState) {
        defer { previousTrustState = newState }

        guard case .failed(.transport(.requiresTrust(let fingerprint, let algorithm, let key))) = newState else {
            pendingTrustChallenge = nil
            return
        }

        let wasAlreadyTrustFailed: Bool
        if case .failed(.transport(.requiresTrust)) = previousTrustState {
            wasAlreadyTrustFailed = true
        } else {
            wasAlreadyTrustFailed = false
        }

        if !wasAlreadyTrustFailed || lastTrustChallengeKey != key {
            trustPromptDismissed = false
            trustErrorMessage = nil
            lastTrustChallengeKey = key
        }

        guard !trustPromptDismissed,
              pendingTrustChallenge?.publicKeyData != key,
              let trustStore,
              !isClosed else { return }

        let connection = descriptor.connection
        Task { [weak self] in
            let challenge = await trustStore.resolveHostTrustChallenge(
                fingerprint: fingerprint,
                algorithm: algorithm,
                publicKeyData: key,
                connection: connection
            )
            guard let self, let challenge else { return }
            guard case .failed(.transport(.requiresTrust(_, _, let currentKey))) = self.state,
                  currentKey == key,
                  !self.trustPromptDismissed else { return }
            self.pendingTrustChallenge = challenge
        }
    }

    /// Cancel: dismiss the prompt only. Never persists trust, never
    /// retries, never opens a shell.
    func cancelTrustPrompt() {
        trustPromptDismissed = true
    }

    /// The explicit Trust gesture: persist through the production verifier,
    /// then reconnect this scene's session. A verifier rejection (changed
    /// key) surfaces as an error and retries nothing.
    func trustPendingHost() async {
        guard let challenge = pendingTrustChallenge, let trustStore else { return }
        let outcome = await trustStore.trustHost(challenge)
        switch outcome {
        case .success:
            trustErrorMessage = nil
            trustPromptDismissed = true
            await reconnect()
        case .failure(let error):
            trustErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Terminal I/O

    nonisolated func send(_ bytes: Data) {
        let registry = self.registry
        let sceneID = self.sceneID
        Task { try? await registry.send(sceneID: sceneID, bytes) }
    }

    nonisolated func resize(cols: Int, rows: Int) {
        let registry = self.registry
        let sceneID = self.sceneID
        Task { await registry.resize(sceneID: sceneID, cols: cols, rows: rows) }
    }

    // MARK: - Closing

    func requestClose() {
        guard !isClosed else { return }
        if requiresCloseConfirmation {
            pendingCloseConfirmation = true
        } else {
            Task { await closeNow() }
        }
    }

    func cancelClose() {
        pendingCloseConfirmation = false
    }

    func confirmClose() {
        pendingCloseConfirmation = false
        Task { await closeNow() }
    }

    func closeNow() async {
        guard !isClosed else { return }
        isClosed = true
        disappearCloseTask?.cancel()
        disappearCloseTask = nil
        stateTask?.cancel()
        stateTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        viewOutputContinuation.finish()
        await onClose(id)
        state = .closed
    }

    /// View-level teardown (window destroyed, cover replaced). Delayed so a
    /// transient SwiftUI unmount can cancel it by reappearing.
    func sceneViewDisappeared() {
        guard !isClosed else { return }
        disappearCloseTask?.cancel()
        disappearCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            await self.closeNow()
        }
    }

    func sceneViewAppeared() {
        disappearCloseTask?.cancel()
        disappearCloseTask = nil
    }
}

#if DEBUG
extension SessionSceneModel {
    var uitestStatusDescription: String {
        switch state {
        case .connecting: "status:connecting"
        case .active: "status:active"
        case .disconnected: "status:disconnected"
        case .reconnecting: "status:reconnecting"
        case .suspended: "status:suspended"
        case .failed(let failure): "status:failed:\(failure.localizedDescription)"
        case .closed: "status:closed"
        }
    }
}
#endif
