import Foundation
import SwiftTerm
import SwiftUI
import UIKit

/// One session's live terminal surface: the SwiftTerm view plus the feed
/// task pumping the session's output stream into it. Owned by
/// ``TerminalViewCache``, not by the SwiftUI placement — detaching a
/// session (switching away, closing its window) keeps the feed running and
/// the scrollback accumulating; only eviction or session close destroys it.
@MainActor
final class TerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    let view: TerminalContainerView
    /// Stacks the terminal above the accessory toolbar when the user shows
    /// it — the surface's SwiftUI placements embed THIS view, never `view`
    /// directly, so the strip is a layout participant rather than an overlay.
    let hostView: TerminalToolbarHostView
    private var feedTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private let sendBytes: @Sendable (Data) -> Void
    private let resizeTo: @Sendable (_ cols: Int, _ rows: Int) -> Void
    /// App-global OSC 52 toggle. Read on every write (cheap UserDefaults
    /// lookup, but cheapness is not the point — the surface is the
    /// trust boundary for the fork's delegate, so it must consult the
    /// live setting, not a cached snapshot).
    private let osc52Settings: Osc52ClipboardSettings
    /// Hook to surface the approved toast on the foreground scene's
    /// model. Nil in previews/tests; nil in production only if the scene
    /// model has already closed. MainActor-isolated (the scene model is
    /// @MainActor).
    private let osc52ToastPresenter: (@MainActor (Osc52ClipboardToast) -> Void)?
    /// Hook for DEBUG denial observability; production keeps this nil.
    private let osc52DenialRecorder: (@MainActor (Osc52ClipboardDenial) -> Void)?
    /// Hook to surface the link-confirmation request on the scene's
    /// model (fork hunk 13 activation). Nil in previews/tests that
    /// construct the surface directly.
    private let linkPresenter: (@MainActor (TerminalLinkRequest) -> Void)?
    /// OSC 777 routing target for this surface; nil keeps the terminal on
    /// SwiftTerm's built-in (no-op delegate) 777 dispatch.
    private let notificationCoordinator: TerminalNotificationCoordinator?
    /// Scene identity the OSC 777 handler reports events under.
    private let notificationSceneID: String
    /// Attribution label baked into every approved toast ("Alpha", "Beta",
    /// …) so the user can tell which remote triggered the clipboard
    /// change. The cache passes this in from the session descriptor.
    let sourceLabel: String

    init(
        output: AsyncStream<Data>,
        resync: AsyncStream<TerminalResyncCommand>,
        send: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (_ cols: Int, _ rows: Int) -> Void,
        fontSize: Double = TerminalFontSettings.defaultSize,
        fontModel: TerminalFontModel? = nil,
        osc52Settings: Osc52ClipboardSettings = Osc52ClipboardSettings(),
        osc52ToastPresenter: (@MainActor (Osc52ClipboardToast) -> Void)? = nil,
        osc52DenialRecorder: (@MainActor (Osc52ClipboardDenial) -> Void)? = nil,
        linkPresenter: (@MainActor (TerminalLinkRequest) -> Void)? = nil,
        notificationCoordinator: TerminalNotificationCoordinator? = nil,
        notificationSceneID: String = "",
        sourceLabel: String = ""
    ) {
        self.sendBytes = send
        self.resizeTo = onResize
        self.osc52Settings = osc52Settings
        self.osc52ToastPresenter = osc52ToastPresenter
        self.osc52DenialRecorder = osc52DenialRecorder
        self.linkPresenter = linkPresenter
        self.notificationCoordinator = notificationCoordinator
        self.notificationSceneID = notificationSceneID
        self.sourceLabel = sourceLabel

        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            cursorStyle: .steadyBlock,
            scrollback: TerminalScrollback.maxLines
        )
        // `fontSize` arrives pre-resolved by the (MainActor) cache: this
        // initializer is nonisolated and cannot read the model directly.
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        self.view = view
        let hostView = TerminalToolbarHostView(terminalView: view)
        self.hostView = hostView
        super.init()

        view.optionAsMetaKey = true
        view.applyNativeTerminalColors()
        // UIKit's inputAccessoryView dock overlays the terminal's bottom rows
        // when a hardware keyboard is attached; the accessory lives in the
        // host view's layout instead. The hosted instance keeps feeding
        // sticky-ctrl state into SwiftTerm's key encoding (fork hunk 8).
        view.inputAccessoryView = nil
        view.hostedAccessory = hostView.accessoryView
        view.terminalDelegate = self
        view.accessibilityIdentifier = "terminalView"
        // Installs pinch-to-zoom when a model is present (nil in tests that
        // construct the cache directly).
        view.fontModel = fontModel

        // Visible BEL + app-side OSC 777 routing (the registered handler
        // replaces SwiftTerm's built-in 777 dispatch).
        TerminalNotificationRouting.apply(
            to: view,
            coordinator: notificationCoordinator,
            sceneID: notificationSceneID
        )

        feedTask = Task { [weak view] in
            for await chunk in output {
                let slice = Array(chunk)[...]
                await MainActor.run {
                    view?.feed(byteArray: slice)
                }
            }
        }

        // Resync commands carry their reset flavor: a suspect screen
        // (loss-corrupted stream, user-tapped resync, or a reconnect while
        // suspect) takes the full RIS — screen, modes, buffers — while a
        // clean reconnect resets session modes only, preserving the
        // transcript. The registry's redraw poke then refills the screen.
        resyncTask = Task { [weak view] in
            for await command in resync {
                await MainActor.run {
                    switch command {
                    case .fullReset:
                        view?.getTerminal().resetToInitialState()
                    case .modesOnly:
                        view?.getTerminal().resetSessionModes()
                    }
                }
            }
        }
    }

    /// Permanent teardown (session closed or cache eviction): stop the
    /// feed and release the view. The in-memory scrollback dies with it.
    func stop() {
        feedTask?.cancel()
        feedTask = nil
        resyncTask?.cancel()
        resyncTask = nil
        view.terminalDelegate = nil
        view.updateUiClosed()
    }

    /// Live font-size application: SwiftTerm's `font` setter rebuilds the
    /// FontSet, recomputes the cell metrics (`resetFont`), resizes the
    /// grid, and reports through `sizeChanged` — which reaches the remote
    /// pty as an SSH window-change via this surface's `resizeTo` closure.
    func applyFont(size: Double) {
        guard view.font.pointSize != size else { return }
        view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendBytes(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        resizeTo(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Fork hunk 13 surfaces direct finger/Pencil taps (and
        // hover-gated pointer clicks) here: forward the immutable
        // request into scene state. The scene presents the host-visible
        // confirmation sheet, and only an explicit Open on a
        // policy-approved http(s) URL reaches the system opener.
        linkPresenter?(TerminalLinkRequest(link: link, params: params))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // Legacy byte-level callback: now a no-op. The fork's parse path
        // routes every write attempt through `oscClipboardWriteRequest`
        // (fork hunk 11) so the host can apply the typed policy at one
        // decision point — foreground gating, size cap, settings toggle,
        // malformed-base64 diagnostics. Kept as an override so
        // `TerminalViewDelegate`'s default extension (which forwards here
        // from the parse path's compat shim) remains satisfied without
        // accidentally writing to the pasteboard twice.
    }

    func oscClipboardWriteRequest(source: TerminalView, request: ClipboardWriteRequest) {
        // OSC 52 WRITE policy: foreground-only, 100 KiB cap, default ON.
        // The fork's parse path surfaces the raw base64 here so malformed
        // payloads stay diagnosable; the policy's raw-base64 entry point
        // is the only path that can return `.malformedBase64`. Approved
        // writes fire an attribution toast on the foreground scene;
        // denials are silent (no toast, no banner) and never touch the
        // pasteboard. Reads are unconditionally denied at the fork's
        // `clipboardRead` default and never reach this layer.
        let capturedView = view
        let outcome = MainActor.assumeIsolated { () -> Osc52ClipboardOutcome in
            let settings = osc52Settings
            let label = sourceLabel.isEmpty ? "Terminal" : sourceLabel
            let foreground: @MainActor () -> Bool = { capturedView.window?.isKeyWindow == true }
            return Osc52Router(
                settings: settings,
                isForeground: foreground
            )
            .evaluate(request, sourceLabel: label)
        }
        MainActor.assumeIsolated {
            applyOsc52Outcome(outcome)
        }
    }

    /// Applies a router outcome: writes/clears fire a toast; denials
    /// record a typed diagnostic (DEBUG) and never touch the pasteboard
    /// or the UI. MainActor-isolated because every consumer (sink,
    /// presenter, recorder) is.
    @MainActor
    private func applyOsc52Outcome(_ outcome: Osc52ClipboardOutcome) {
        switch outcome.decision {
        case .write(let text, let bytes):
            Osc52ClipboardSink.write(text)
            osc52ToastPresenter?(
                Osc52ClipboardToast(kind: .copied(bytes: bytes), sourceLabel: outcome.sourceLabel)
            )
        case .clear:
            Osc52ClipboardSink.clear()
            osc52ToastPresenter?(
                Osc52ClipboardToast(kind: .cleared, sourceLabel: outcome.sourceLabel)
            )
        case .deny(let reason):
            #if DEBUG
            Osc52ClipboardSink.recordDenial(reason)
            #endif
            osc52DenialRecorder?(reason)
        }
    }
}

/// Strong LRU cache (cap 8) of live terminal surfaces keyed by session
/// descriptor ID — the buffer-preservation layer for detach-without-close:
///
/// - attach  = return the cached surface (or create it) and swap its view
///   into the calling hierarchy; recency moves to the front.
/// - detach  = the placement's view left the hierarchy; the entry STAYS,
///   the feed keeps running, the session keeps receiving output.
/// - evict   = capacity exceeded: the least-recently-attached surface is
///   stopped and dropped. The session survives; its scrollback does not —
///   re-attaching builds a fresh surface and flags the model so the scene
///   shows a one-line "scrollback released" notice.
/// - remove  = session closed: drop the entry unconditionally.
///
/// Attach/detach bookkeeping is generation-stamped: each attach bumps a
/// per-session counter, and a dismantle only reports the detach when no
/// NEWER attach has claimed the surface. This survives both SwiftUI's
/// dismantle ordering (which can run while the view is still in the
/// hierarchy) and a surface stolen by another window's attach.
@MainActor
final class TerminalViewCache {
    struct SurfaceAttachment {
        let surface: TerminalSurface
        let generation: UInt64
    }

    private struct Entry {
        let surface: TerminalSurface
        let onDetach: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var recencyOrder: [UUID] = []
    private var attachGenerations: [UUID: UInt64] = [:]
    private var evictedSessionIDs: Set<UUID> = []

    /// Global fallback for standalone caches. SessionStore supplies scene
    /// resolution and pinch routing so explicit overrides remain independent.
    var fontModel: TerminalFontModel?
    var resolveFontSize: ((String) -> Double)?
    var onSceneFontPinch: ((String, Double) -> Void)?
    /// App-global OSC 52 clipboard settings. SessionStore wires a shared
    /// instance so the toggle in Settings applies to every surface at once.
    var osc52Settings: Osc52ClipboardSettings = Osc52ClipboardSettings()
    /// App-side OSC 777 notification routing: one coordinator shared by
    /// every session surface, keyed by registry scene ID. Owned here (with
    /// the session state); injectable for focused tests.
    var notificationCoordinator = TerminalNotificationCoordinator()

    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    var cachedCount: Int { entries.count }

    func resetSessionState(for sessionID: UUID) {
        entries[sessionID]?.surface.view.getTerminal().resetSessionModes()
    }

    /// Re-fonts every live surface (attached or detached). SwiftTerm's font
    /// setter recomputes cell metrics and resizes the grid, so each
    /// surface's `sizeChanged` → `onResize` chain emits an SSH
    /// window-change to its remote pty.
    func applyFontSize(_ size: Double) {
        for entry in entries.values {
            entry.surface.applyFont(size: size)
        }
    }

    func applyFontSize(_ size: Double, for sessionID: UUID) {
        entries[sessionID]?.surface.applyFont(size: size)
    }

    @discardableResult
    func attachSurface(for sessionID: UUID, model: SessionSceneModel) -> SurfaceAttachment {
        let generation = (attachGenerations[sessionID] ?? 0) &+ 1
        attachGenerations[sessionID] = generation
        model.attachNotificationCoordinator(notificationCoordinator)

        if let entry = entries[sessionID] {
            touch(sessionID)
            wirePastePreview(on: entry.surface.view, model: model)
            model.surfaceAttached()
            #if DEBUG
            Self.maybeFireUITestOsc52Trigger(on: entry.surface, connectionName: model.connectionName)
            #endif
            return SurfaceAttachment(surface: entry.surface, generation: generation)
        }

        let wasEvicted = evictedSessionIDs.remove(sessionID) != nil
        let sourceLabel = model.connectionName
        let surface = TerminalSurface(
            output: model.beginOutputStream(),
            resync: model.resyncCommands,
            send: { model.send($0) },
            onResize: { cols, rows in model.resize(cols: cols, rows: rows) },
            fontSize: resolveFontSize?(model.sceneID) ?? fontModel?.size ?? TerminalFontSettings.defaultSize,
            fontModel: fontModel,
            osc52Settings: osc52Settings,
            osc52ToastPresenter: { toast in model.presentOsc52Toast(toast) },
            osc52DenialRecorder: { reason in model.recordOsc52Denial(reason) },
            linkPresenter: { request in model.presentLinkConfirmation(request) },
            notificationCoordinator: notificationCoordinator,
            notificationSceneID: model.sceneID,
            sourceLabel: sourceLabel
        )
        let sceneID = model.sceneID
        if let onSceneFontPinch {
            surface.view.onFontPinch = { size in onSceneFontPinch(sceneID, size) }
        }
        wirePastePreview(on: surface.view, model: model)
        entries[sessionID] = Entry(
            surface: surface,
            onDetach: { [weak model] in model?.surfaceDetached() }
        )
        recencyOrder.append(sessionID)
        evictIfNeeded()
        if wasEvicted {
            model.markScrollbackReleased()
        }
        model.surfaceAttached()
        #if DEBUG
        Self.maybeFireUITestOsc52Trigger(on: surface, connectionName: sourceLabel)
        #endif
        return SurfaceAttachment(surface: surface, generation: generation)
    }

    /// The placement that owned `generation` left the hierarchy. A newer
    /// attach has claimed the surface when the current generation differs
    /// — in that case the session is still attached and nothing is
    /// reported.
    func detachSurface(for sessionID: UUID, generation: UInt64) {
        guard let entry = entries[sessionID],
              attachGenerations[sessionID] == generation else { return }
        entry.onDetach()
    }

    /// Wires the multi-line paste preview for one session surface: the
    /// view's intercept presenter routes captured requests into scene
    /// state, and the model's confirm path resolves bracketed-paste
    /// framing and first-responder restoration against THIS surface's
    /// view. Idempotent across re-attaches.
    private func wirePastePreview(on view: TerminalContainerView, model: SessionSceneModel) {
        view.pastePreviewPresenter = { [weak model] request in
            model?.presentPasteConfirmation(request)
        }
        model.attachPasteSurfaceHooks(
            framePaste: { [weak view] text in
                TerminalPastePolicy.framedBytes(
                    for: text,
                    bracketed: view?.getTerminal().bracketedPasteMode ?? false
                )
            },
            refocus: { [weak view] in
                view?.becomeFirstResponder()
            }
        )
    }

    /// Session close: drop the entry unconditionally. The evicted marker
    /// is set so a surface ever rebuilt for this ID reports released
    /// scrollback — the previous buffer was discarded either way.
    func removeSurface(for sessionID: UUID) {
        if let entry = entries.removeValue(forKey: sessionID) {
            entry.surface.stop()
            evictedSessionIDs.insert(sessionID)
        }
        recencyOrder.removeAll { $0 == sessionID }
    }

    private func touch(_ sessionID: UUID) {
        recencyOrder.removeAll { $0 == sessionID }
        recencyOrder.append(sessionID)
    }

    private func evictIfNeeded() {
        while recencyOrder.count > capacity, let lru = recencyOrder.first {
            recencyOrder.removeFirst()
            if let entry = entries.removeValue(forKey: lru) {
                entry.surface.stop()
            }
            evictedSessionIDs.insert(lru)
        }
    }

    #if DEBUG
    /// DEBUG-only UI smoke helper: the `--uitest-osc52-trigger` launch
    /// argument makes every session-scene surface attach fire an
    /// `OSC 52 ; c ; <base64>` sequence directly into the live terminal,
    /// exercising the production `oscClipboardWriteRequest` →
    /// `Osc52Router` → toast path end-to-end without needing raw HID
    /// injection through the simulator.
    ///
    /// Waits for `view.window?.isKeyWindow == true` before feeding —
    /// the same predicate the policy's foreground gate reads. A freshly
    /// opened iPad window scene can attach its terminal surface before
    /// SwiftUI installs the representable into the window hierarchy, so
    /// firing at a fixed runloop tick races key-window promotion and
    /// the write is silently denied (no toast). Bounded (5 s) so a
    /// window that never keys still feeds and surfaces a real defect.
    private static func maybeFireUITestOsc52Trigger(
        on surface: TerminalSurface,
        connectionName: String
    ) {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-osc52-trigger") else {
            return
        }
        DispatchQueue.main.async {
            let view = surface.view
            let deadline = Date().addingTimeInterval(5.0)
            func feed() {
                let payload = "aGVsbG8gZnJvbSBoZXJkciE="  // "hello from herdr!"
                let bytes: [UInt8] = Array("\u{1B}]52;c;\(payload)\u{07}".utf8)
                view.feed(byteArray: bytes[...])
            }
            if view.window?.isKeyWindow == true {
                feed()
                return
            }
            func poll() {
                if view.window?.isKeyWindow == true {
                    feed()
                } else if Date() >= deadline {
                    feed()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: poll)
                }
            }
            poll()
        }
    }
    #endif
}

/// Cache-backed terminal surface for session scenes. `makeUIView` pulls
/// the session's live surface from the cache (creating it on first
/// attach); `dismantleUIView` detaches WITHOUT stopping the feed — the
/// session keeps running and its scrollback keeps accumulating while no
/// view is on screen.
struct SessionTerminalRepresentable: UIViewRepresentable {
    let cache: TerminalViewCache
    let model: SessionSceneModel
    /// Whether the accessory toolbar strip participates in the layout below
    /// the terminal (app-global pref from `SessionStore.terminalToolbar`).
    var toolbarVisible: Bool = false
    /// App-global sticky keyboard-dismiss state (same model): applied to
    /// this surface's terminal through the fork's runtime toggle.
    var keyboardHidden: Bool = false
    /// Dismiss-control action → app-global model hide.
    var onDismissKeyboard: (() -> Void)? = nil
    /// Terminal-tap re-enable → app-global model show (the tapped host
    /// refocuses its own terminal).
    var onTerminalTap: (() -> Void)? = nil

    final class Coordinator {
        let cache: TerminalViewCache
        let sessionID: UUID
        var attachGeneration: UInt64 = 0

        init(cache: TerminalViewCache, sessionID: UUID) {
            self.cache = cache
            self.sessionID = sessionID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cache: cache, sessionID: model.id)
    }

    func makeUIView(context: Context) -> TerminalToolbarHostView {
        let attachment = cache.attachSurface(for: model.id, model: model)
        context.coordinator.attachGeneration = attachment.generation
        let hostView = attachment.surface.hostView
        hostView.setAccessoryVisible(toolbarVisible)
        hostView.tracksKeyboardFrame = true
        hostView.onDismissKeyboard = onDismissKeyboard
        hostView.onTerminalTap = onTerminalTap
        hostView.setKeyboardHidden(keyboardHidden)
        return hostView
    }

    func updateUIView(_ uiView: TerminalToolbarHostView, context: Context) {
        uiView.setAccessoryVisible(toolbarVisible)
        uiView.tracksKeyboardFrame = true
        uiView.onDismissKeyboard = onDismissKeyboard
        uiView.onTerminalTap = onTerminalTap
        uiView.setKeyboardHidden(keyboardHidden)
    }

    static func dismantleUIView(_ uiView: TerminalToolbarHostView, coordinator: Coordinator) {
        coordinator.cache.detachSurface(
            for: coordinator.sessionID,
            generation: coordinator.attachGeneration
        )
    }
}
