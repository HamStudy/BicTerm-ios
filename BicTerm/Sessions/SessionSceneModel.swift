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
    /// Process-wide snippet persistence (global + per-connection
    /// snippets). Injectable for tests; defaults to the app-services
    /// erased store.
    private let snippetStore: any SnippetStoreProtocol

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
        trustStore: SessionStore? = nil,
        snippetStore: (any SnippetStoreProtocol)? = nil
    ) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.sceneID = descriptor.registrySceneID
        self.connectionName = descriptor.connection.name
        self.registry = registry
        self.onClose = onClose
        self.trustStore = trustStore
        self.snippetStore = snippetStore ?? AppServices.shared.snippetStore
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
                if newState != .active {
                    // A pending paste or snippet Run targets the CURRENT
                    // shell; a reconnect/suspend/disconnect invalidates it.
                    self.invalidatePendingPaste()
                    self.invalidatePendingSnippetRun()
                }
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

    // MARK: - Multi-line paste preview (t4)

    /// Immutable captured-text paste request pending confirmation; nil
    /// when no preview is pending. A second paste while one is pending
    /// REPLACES it — never two queued sheets.
    private(set) var pendingPasteRequest: TerminalPasteRequest?

    /// Inline error retained in the sheet when a confirmed send fails.
    /// A non-nil error keeps the sheet up so the user can retry or
    /// cancel; a successful confirm clears it.
    private(set) var pasteErrorMessage: String?

    /// Attachment generation the pending request was captured under.
    /// Bumped by every surface attach AND detach; a request whose
    /// generation no longer matches is stale and can never send.
    private var surfaceGeneration: UInt64 = 0
    private var pendingPasteGeneration: UInt64?

    /// True while a confirm is awaiting the registry send; a second
    /// confirm (double-tap) must not enqueue a second delivery.
    private var pasteConfirmationInFlight = false

    /// Resolves a confirmed paste into wire bytes, applying the
    /// terminal's CURRENT bracketed-paste framing. Wired by the view
    /// cache at surface attach; nil frames as plain UTF-8.
    private var pasteByteFramer: (@MainActor (String) -> Data)?

    /// Restores first responder to the terminal after the sheet
    /// dismisses. Wired by the view cache at surface attach.
    private var pasteRefocus: (@MainActor () -> Void)?

    /// The request the confirmation sheet should present right now:
    /// nil when nothing is pending OR the pending request's attachment
    /// generation went stale (surface rebind) — the sheet dismisses
    /// reactively in both cases.
    var currentPasteRequest: TerminalPasteRequest? {
        guard let request = pendingPasteRequest,
              pendingPasteGeneration == surfaceGeneration else { return nil }
        return request
    }

    /// Cache-wired surface hooks (idempotent across re-attaches).
    func attachPasteSurfaceHooks(
        framePaste: @escaping @MainActor (String) -> Data,
        refocus: @escaping @MainActor () -> Void
    ) {
        pasteByteFramer = framePaste
        pasteRefocus = refocus
    }

    /// A multi-line paste was intercepted on this scene's terminal:
    /// present the confirmation sheet. The request is immutable from
    /// here on — the sheet renders and (on confirm) delivers exactly
    /// the captured text.
    func presentPasteConfirmation(_ request: TerminalPasteRequest) {
        guard !isClosed else { return }
        pendingPasteRequest = request
        pendingPasteGeneration = surfaceGeneration
        pasteErrorMessage = nil
    }

    /// Cancel (or swipe-down) dismisses the sheet and sends nothing.
    func cancelPasteConfirmation() {
        pendingPasteRequest = nil
        pendingPasteGeneration = nil
        pasteErrorMessage = nil
        pasteRefocus?()
    }

    /// The ONLY delivery path for an intercepted paste: requires the
    /// pending request AND a current attachment generation, sends the
    /// captured string through the registry's throwing seam, and
    /// dismisses only on confirmed delivery. A send failure retains the
    /// sheet with an inline error.
    func confirmPaste() async {
        guard !pasteConfirmationInFlight else { return }
        guard let request = pendingPasteRequest,
              let generation = pendingPasteGeneration,
              generation == surfaceGeneration, !isClosed else {
            invalidatePendingPaste()
            return
        }
        pasteConfirmationInFlight = true
        defer { pasteConfirmationInFlight = false }

        let bytes = pasteByteFramer?(request.text) ?? Data(request.text.utf8)
        do {
            try await registry.send(sceneID: sceneID, bytes)
            guard surfaceGeneration == generation, !isClosed else {
                // The surface rebound mid-send; the bytes were already
                // delivered to the session. Clear silently.
                invalidatePendingPaste()
                return
            }
            pendingPasteRequest = nil
            pendingPasteGeneration = nil
            pasteErrorMessage = nil
            pasteRefocus?()
        } catch {
            pasteErrorMessage = (error as? SessionRegistryError)?.localizedDescription
                ?? String(describing: error)
        }
    }

    /// Drops a pending request without sending. Called on background,
    /// non-active session states, and surface detach.
    private func invalidatePendingPaste() {
        pendingPasteRequest = nil
        pendingPasteGeneration = nil
        pasteErrorMessage = nil
    }

    // MARK: - Snippets (t8)

    /// Snippets visible to this scene's connection (global plus
    /// connection-scoped), in the store's deterministic order. Loaded
    /// when the snippet sheet opens.
    private(set) var snippets: [Snippet] = []

    /// Load failure for the snippet sheet.
    private(set) var snippetLoadError: String?

    /// Inline error from a failed snippet Insert; shown in the snippet
    /// sheet. A non-nil error keeps the sheet up; a successful insert
    /// clears it and the view dismisses.
    private(set) var snippetErrorMessage: String?

    /// Immutable Run request pending confirmation; nil when none. A
    /// second Run while one is pending REPLACES it — never two queued
    /// confirmations.
    private(set) var pendingSnippetRunRequest: TerminalSnippetRunRequest?

    /// Inline error retained when a confirmed Run fails delivery; a
    /// non-nil error keeps the confirmation up so the user can retry or
    /// cancel.
    private(set) var snippetRunErrorMessage: String?

    /// Attachment generation the Run request was captured under — the
    /// t4 paste discipline: a request whose generation no longer matches
    /// (surface rebind) can never send.
    private var pendingSnippetRunGeneration: UInt64?

    /// True while a Run confirm is awaiting the registry send; a second
    /// confirm (double-tap) must not enqueue a second delivery.
    private var snippetRunInFlight = false

    /// The request the snippet sheet should confirm right now: nil when
    /// nothing is pending OR the pending request's attachment
    /// generation went stale (surface rebind) — the confirmation
    /// content leaves in both cases.
    var currentSnippetRunRequest: TerminalSnippetRunRequest? {
        guard let request = pendingSnippetRunRequest,
              pendingSnippetRunGeneration == surfaceGeneration else { return nil }
        return request
    }

    /// Loads global plus connection-scoped snippets for THIS scene's
    /// connection.
    func reloadSnippets() async {
        do {
            snippets = try await snippetStore.snippets(connectionID: descriptor.connection.id)
            snippetLoadError = nil
        } catch {
            snippetLoadError = error.localizedDescription
        }
    }

    /// Insert: deliver the snippet's exact command bytes with NO Return
    /// through the registry's throwing seam. A failure keeps the sheet
    /// up with the error inline.
    func insertSnippet(_ snippet: Snippet) async {
        guard !isClosed else { return }
        snippetErrorMessage = nil
        do {
            try await registry.send(sceneID: sceneID, Data(snippet.command.utf8))
        } catch {
            snippetErrorMessage = Self.snippetSendErrorMessage(error)
        }
    }

    /// A Run was requested: present the confirmation. The request is
    /// immutable from here on — the sheet renders and (on confirm)
    /// delivers exactly the captured command.
    func presentSnippetRunConfirmation(_ request: TerminalSnippetRunRequest) {
        guard !isClosed else { return }
        pendingSnippetRunRequest = request
        pendingSnippetRunGeneration = surfaceGeneration
        snippetRunErrorMessage = nil
    }

    /// Cancel (or sheet dismissal) drops the request without sending.
    func cancelSnippetRunConfirmation() {
        pendingSnippetRunRequest = nil
        pendingSnippetRunGeneration = nil
        snippetRunErrorMessage = nil
    }

    /// The ONLY delivery path for a confirmed Run: requires the pending
    /// request AND a current attachment generation, sends the exact
    /// command bytes plus CR (0x0D) exactly once through the registry's
    /// throwing seam. A send failure retains the confirmation with an
    /// inline error.
    func confirmSnippetRun() async {
        guard !snippetRunInFlight else { return }
        guard let request = pendingSnippetRunRequest,
              let generation = pendingSnippetRunGeneration,
              generation == surfaceGeneration, !isClosed else {
            invalidatePendingSnippetRun()
            return
        }
        snippetRunInFlight = true
        defer { snippetRunInFlight = false }

        do {
            try await registry.send(sceneID: sceneID, Data(request.command.utf8) + Data([0x0D]))
            guard surfaceGeneration == generation, !isClosed else {
                // The surface rebound mid-send; the bytes were already
                // delivered to the session. Clear silently.
                invalidatePendingSnippetRun()
                return
            }
            pendingSnippetRunRequest = nil
            pendingSnippetRunGeneration = nil
            snippetRunErrorMessage = nil
        } catch {
            snippetRunErrorMessage = Self.snippetSendErrorMessage(error)
        }
    }

    /// Drops a pending Run request without sending. Called on
    /// background, non-active session states, and surface detach.
    private func invalidatePendingSnippetRun() {
        pendingSnippetRunRequest = nil
        pendingSnippetRunGeneration = nil
        snippetRunErrorMessage = nil
    }

    private static func snippetSendErrorMessage(_ error: any Error) -> String {
        (error as? SessionRegistryError)?.localizedDescription ?? String(describing: error)
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
            invalidatePendingPaste()
            invalidatePendingSnippetRun()
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
        // A new placement claimed the surface: any pending paste was
        // captured under an older attachment and must never send.
        surfaceGeneration &+= 1
        presentationCommands.yield(.attached)
    }

    func surfaceDetached() {
        guard !isClosed else { return }
        surfaceGeneration &+= 1
        invalidatePendingPaste()
        invalidatePendingSnippetRun()
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
        invalidatePendingPaste()
        invalidatePendingSnippetRun()
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
