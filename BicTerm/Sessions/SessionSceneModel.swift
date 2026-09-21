import BicTermCore
import Foundation
import SwiftUI

/// What a resync command asks the session's terminal surface to reset.
/// A suspect local screen (loss-corrupted stream, or the user tapped
/// Resync because it looks wrong) needs the full RIS; a clean reconnect
/// only needs the replaced shell's input modes cleared so the
/// transcript survives.
enum TerminalResyncCommand: Sendable {
    /// Full VT reset (RIS semantics: screen, modes, buffers).
    case fullReset
    /// Resets session protocol modes (mouse, bracketed paste, cursor/
    /// keypad, alt-screen) while preserving the transcript.
    case modesOnly
}

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
    private(set) var lastRetryableTransition = Date.distantPast
    var onReconnect: (@MainActor () -> Void)?
    private(set) var launchErrorMessage: String?
    private(set) var pendingCloseConfirmation = false
    private(set) var isClosed = false
    private(set) var tail = ""
    private(set) var pendingTrustChallenge: SessionStore.HostTrustChallenge?
    private(set) var trustErrorMessage: String?
    /// True after the session's cached terminal surface was evicted and a
    /// re-attach built a fresh one — the scene shows the one-line
    /// "scrollback released" notice until the user dismisses it.
    private(set) var scrollbackReleased = false
    /// True when an inbound-chain anomaly (silent-drop detection) left the
    /// local VT suspect — the scene shows the "Screen may be out of sync"
    /// banner until the user resyncs.
    private(set) var syncSuspect = false
    /// Briefly true after a reconnect-driven screen refresh.
    private(set) var showReconnectedToast = false
    /// Live OSC 52 clipboard toast for this scene; nil when none is
    /// showing. A new event replaces the previous one and re-arms the
    /// auto-dismiss timer. Source attribution (`connectionName`) and the
    /// byte count travel with the event so the UI renders the exact
    /// message the policy approved.
    private(set) var osc52Toast: Osc52ClipboardToast?
    /// DEBUG-only observability: the last denial this scene recorded so
    /// a UI suite can assert the policy fired the expected branch.
    #if DEBUG
    private(set) var lastOsc52Denial: Osc52ClipboardDenial?
    #endif
    /// OSC 777 banner coordinator, attached by the view cache when this
    /// scene's surface wires in. Nil until the first attach (a detached
    /// session has no banner surface).
    private(set) var notificationCoordinator: TerminalNotificationCoordinator?

    let viewOutput: AsyncStream<Data>
    private var viewOutputContinuation: AsyncStream<Data>.Continuation
    /// Local VT reset commands for the session's terminal surface (one
    /// consumer: the surface's resync task).
    let resyncCommands: AsyncStream<TerminalResyncCommand>
    private var resyncCommandContinuation: AsyncStream<TerminalResyncCommand>.Continuation

    private var stateTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var osc52ToastTask: Task<Void, Never>?
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
        let (resyncStream, resyncContinuation) = AsyncStream<TerminalResyncCommand>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.resyncCommands = resyncStream
        self.resyncCommandContinuation = resyncContinuation

        let (commands, commandContinuation) = AsyncStream<SurfacePresentation>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.presentationCommands = commandContinuation
        Task { [weak self] in
            for await command in commands {
                guard let self else { return }
                switch command {
                case .attached:
                    await self.registry.attached(sceneID: self.sceneID)
                case .detached:
                    await self.registry.detached(sceneID: self.sceneID)
                }
            }
        }

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
                let wasRetryable = self.canRetry
                if newState == .reconnecting, self.state != .reconnecting {
                    self.onReconnect?()
                }
                self.state = newState
                if self.canRetry, !wasRetryable {
                    self.lastRetryableTransition = Date()
                }
                self.updateTrustChallenge(for: newState)
            }
        }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.registry.output(sceneID: self.sceneID) else { return }
            var tailBytes = Data()
            for await chunk in stream {
                if case .dropped = self.viewOutputContinuation.yield(chunk) {
                    self.syncSuspect = true
                }
                tailBytes.append(chunk)
                if tailBytes.count > 8_192 {
                    tailBytes.removeFirst(tailBytes.count - 8_192)
                }
                self.tail = String(decoding: tailBytes, as: UTF8.self)
            }
        }
        syncTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.registry.syncEvents(sceneID: self.sceneID) else { return }
            for await event in stream {
                switch event {
                case .sessionReplaced:
                    self.refreshTerminalAfterReconnect()
                case .inboundDropped:
                    self.syncSuspect = true
                }
            }
        }
    }

    /// A rehandshaked session was adopted: the remote shell was replaced,
    /// so the local surface is reset and the remote poked into a redraw.
    /// A suspect stream takes the full RIS (its screen cannot be trusted);
    /// a clean reconnect resets modes only, preserving the transcript.
    /// Normal reconnects surface as a brief toast; a suspect stream keeps
    /// the louder banner up instead.
    private func refreshTerminalAfterReconnect() {
        resyncCommandContinuation.yield(syncSuspect ? .fullReset : .modesOnly)
        if syncSuspect {
            return
        }
        showReconnectedToast = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.showReconnectedToast = false
        }
    }

    /// Surface the OSC 52 toast for an approved write or clear event.
    /// Auto-dismisses after ~3s; a fresh event replaces the previous one
    /// and re-arms the timer. Denials are recorded separately (DEBUG only)
    /// and never produce a toast.
    func presentOsc52Toast(_ toast: Osc52ClipboardToast) {
        osc52Toast = toast
        osc52ToastTask?.cancel()
        osc52ToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.osc52Toast = nil
        }
    }

    // MARK: - Terminal notifications (OSC 777)

    /// The scene's live OSC 777 banner, if any. Forwards to the
    /// coordinator's per-scene state; tracked through @Observable when
    /// read from a view body.
    var notificationBanner: TerminalNotificationBanner? {
        notificationCoordinator?.banner(for: sceneID)
    }

    /// Wired by the view cache at surface attach (idempotent).
    func attachNotificationCoordinator(_ coordinator: TerminalNotificationCoordinator) {
        notificationCoordinator = coordinator
    }

    /// Manual dismiss of this scene's OSC 777 banner (its × button).
    func dismissNotificationBanner() {
        notificationCoordinator?.dismissBanner(for: sceneID)
    }

    // MARK: - Link confirmation (OSC 8 / implicit)

    /// Immutable link-open request from a terminal tap (fork hunk 13
    /// surfaces direct finger/Pencil activation); nil when no
    /// confirmation is pending.
    private(set) var pendingLinkRequest: TerminalLinkRequest?

    /// Opener used by ``confirmLinkOpen()``; nil (production) uses the
    /// system opener. Injectable for tests.
    var linkOpener: (@MainActor (URL) -> Void)?

    /// A terminal tap surfaced a link: present the confirmation sheet.
    /// The request is immutable from here on — the sheet renders exactly
    /// what the terminal reported.
    func presentLinkConfirmation(_ request: TerminalLinkRequest) {
        guard !isClosed else { return }
        pendingLinkRequest = request
    }

    /// Cancel (or swipe-down) dismisses the sheet and sends nothing.
    func cancelLinkConfirmation() {
        pendingLinkRequest = nil
    }

    /// The ONLY path to the system opener: requires the pending request
    /// AND a policy-approved http(s) URL. Consumes the request.
    func confirmLinkOpen() {
        guard let request = pendingLinkRequest else { return }
        pendingLinkRequest = nil
        guard TerminalLinkPolicy.evaluate(request.link).canOpen,
              let url = URL(string: request.link)
        else { return }
        let opener = linkOpener ?? Self.openLinkThroughSystem
        opener(url)
    }

    private static func openLinkThroughSystem(_ url: URL) {
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// DEBUG-only: record a denial so UI suites can prove the right
    /// branch fired without depending on the global `Osc52ClipboardSink`
    /// counters.
    func recordOsc52Denial(_ reason: Osc52ClipboardDenial) {
        lastOsc52Denial = reason
    }
    #endif

    /// One-tap resync from the out-of-sync banner: local VT reset plus a
    /// remote redraw poke. Clears the suspicion — the screen is being
    /// rebuilt from fresh remote state. Always a full reset: the user
    /// tapped because the screen looks wrong.
    func resyncNow() {
        guard !isClosed else { return }
        syncSuspect = false
        resyncCommandContinuation.yield(.fullReset)
        let registry = self.registry
        let sceneID = self.sceneID
        Task { await registry.resync(sceneID: sceneID) }
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

    /// Replaces the view-facing output stream (the previous consumer was
    /// cancelled with an evicted surface) and returns the fresh stream for
    /// the new surface's feed task. The pump task yields into whichever
    /// continuation is current.
    func beginOutputStream() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        viewOutputContinuation = continuation
        return stream
    }

    // MARK: - Surface attach/detach (presentation state)

    private enum SurfacePresentation: Sendable {
        case attached
        case detached
    }

    private let presentationCommands: AsyncStream<SurfacePresentation>.Continuation

    /// Attach/detach MUST reach the registry in the order the surfaces
    /// actually came and went — fire-and-forget Tasks can start out of
    /// order under load, and a late "attached" would swallow the unread
    /// marking for a detached session. A serial stream drain guarantees
    /// FIFO per session.
    func surfaceAttached() {
        guard !isClosed else { return }
        presentationCommands.yield(.attached)
    }

    func surfaceDetached() {
        guard !isClosed else { return }
        presentationCommands.yield(.detached)
    }

    func markScrollbackReleased() {
        scrollbackReleased = true
    }

    func clearScrollbackReleasedNotice() {
        scrollbackReleased = false
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
        stateTask?.cancel()
        stateTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        syncTask?.cancel()
        syncTask = nil
        toastTask?.cancel()
        toastTask = nil
        osc52ToastTask?.cancel()
        osc52ToastTask = nil
        viewOutputContinuation.finish()
        resyncCommandContinuation.finish()
        presentationCommands.finish()
        await onClose(id)
        state = .closed
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

    var uitestSyncDescription: String {
        if syncSuspect { "sync:suspect" }
        else if showReconnectedToast { "sync:refreshed" }
        else { "sync:clean" }
    }
}
#endif
