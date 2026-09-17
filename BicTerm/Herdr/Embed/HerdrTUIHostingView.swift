import SwiftTerm
import SwiftUI
import UIKit

/// SwiftUI host for the embedded herdr TUI: a SwiftTerm `TerminalView`
/// rendering the pty master's output. Keystrokes (and SwiftTerm's own
/// replies to the client's terminal capability queries — cell size
/// `CSI 16 t`, OSC 10/11, OSC 4 palette) flow back through
/// ``HerdrEmbedRuntime/writeInput``; geometry changes go through
/// ``HerdrEmbedRuntime/setWinsize(cols:rows:)`` (TIOCSWINSZ + SIGWINCH on
/// the Rust side). Font/geometry are SwiftTerm's own metrics — nothing is
/// quantized app-side.
struct HerdrTUIHostingView: UIViewRepresentable {
    let runtime: HerdrEmbedRuntime
    var fontModel: TerminalFontModel? = nil
    /// Whether the esc/ctrl/tab/arrows accessory strip participates in the
    /// layout below the surface — the app-global `SessionStore.terminalToolbar`
    /// pref, same contract as SSH session surfaces (the terminal shrinks by
    /// the strip's height; the strip never covers the bottom row).
    var toolbarVisible: Bool = false
    var osc52Settings: Osc52ClipboardSettings = Osc52ClipboardSettings()
    /// Optional foreground check; nil = always foreground (tests).
    var osc52ForegroundCheck: (@MainActor () -> Bool)? = nil
    /// Optional toast presenter; nil = no toast (previews/tests).
    var osc52ToastPresenter: (@MainActor (Osc52ClipboardToast) -> Void)? = nil
    var osc52DenialRecorder: (@MainActor (Osc52ClipboardDenial) -> Void)? = nil
    /// Attribution label baked into every approved toast; default
    /// "Herdr" — the workspace view passes the endpoint label
    /// ("Alpha", "Beta", or the herd name) when it mounts this.
    var osc52SourceLabel: String = "Herdr"

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> TerminalToolbarHostView {
        let resolvedSize = fontModel.map { CGFloat($0.size) } ?? 14
        let font = UIFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        // 80×24 placeholder grid: the real geometry arrives with the first
        // layout, which resizes the embedded client before the first paint.
        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            // Steady cursor, matching the session surfaces (TerminalSurface):
            // a blinking cursor animates continuously, which reads as
            // perpetual main-thread activity to XCUI's idle wait (menu
            // taps and typeText hang ~15s and fail) and never idles.
            cursorStyle: .steadyBlock,
            scrollback: TerminalScrollback.maxLines
        )
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        let hostView = TerminalToolbarHostView(terminalView: view)
        view.fontModel = fontModel
        view.optionAsMetaKey = true
        // UIKit's inputAccessoryView dock overlays the surface's bottom rows;
        // the accessory lives in the host view's layout instead (same wiring
        // as TerminalSurface). `hostedAccessory` keeps the accessory's
        // sticky-ctrl state feeding SwiftTerm's key encoding (fork hunk 8).
        view.inputAccessoryView = nil
        view.hostedAccessory = hostView.accessoryView
        view.applyNativeTerminalColors()
        view.terminalDelegate = context.coordinator
        view.accessibilityIdentifier = "herdr-embed-tui"
        hostView.setAccessoryVisible(toolbarVisible)
        context.coordinator.startFeeding(into: view, runtime: runtime)
        return hostView
    }

    func updateUIView(_ uiView: TerminalToolbarHostView, context: Context) {
        context.coordinator.parent = self
        uiView.setAccessoryVisible(toolbarVisible)
        let terminal = uiView.terminalView
        if let liveSize = fontModel?.size, terminal.font.pointSize != CGFloat(liveSize) {
            terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(liveSize), weight: .regular)
        }
    }

    static func dismantleUIView(_ uiView: TerminalToolbarHostView, coordinator: Coordinator) {
        coordinator.stopFeeding()
        uiView.terminalView.delegate = nil
        uiView.terminalView.updateUiClosed()
    }

    /// SwiftTerm delegate: input toward the embedded client, geometry toward
    /// the pty window. Remote clipboard writes (OSC 52) follow the
    /// foreground-only, 100 KiB cap, default-ON policy — the embedded TUI
    /// inherits the same hardening as SSH terminal sessions. Reads stay
    /// denied at the fork's `clipboardRead` default; writes route through
    /// `oscClipboardWriteRequest` (fork hunk 11) so the policy has the
    /// raw base64 for malformed-payload diagnostics.
    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: HerdrTUIHostingView
        private var feedTask: Task<Void, Never>?

        init(parent: HerdrTUIHostingView) {
            self.parent = parent
        }

        func startFeeding(into view: TerminalContainerView, runtime: HerdrEmbedRuntime) {
            feedTask?.cancel()
            guard let output = MainActor.assumeIsolated({ runtime.output }) else { return }
            feedTask = Task { [weak view] in
                for await chunk in output {
                    guard let view else { return }
                    let slice = Array(chunk)[...]
                    await MainActor.run {
                        // A drop episode was armed while the consumer was
                        // stalled: reset the local VT state BEFORE feeding
                        // any post-drop byte, then poke the client's full
                        // redraw (the T12 resync pair).
                        if runtime.takeResyncIfPending() {
                            view.getTerminal().resetToInitialState()
                            runtime.resyncPokeRedraw()
                        }
                        view.feed(byteArray: slice)
                    }
                }
            }
        }

        func stopFeeding() {
            feedTask?.cancel()
            feedTask = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            let runtime = parent.runtime
            MainActor.assumeIsolated {
                runtime.writeInput(bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let runtime = parent.runtime
            MainActor.assumeIsolated {
                runtime.setWinsize(cols: newCols, rows: newRows)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // Legacy byte-level callback: no-op. The fork's parse path
            // routes every write attempt through `oscClipboardWriteRequest`
            // (hunk 11) so the host applies the typed policy at one
            // decision point — foreground gating, size cap, settings
            // toggle, malformed-base64 diagnostics. Kept as an override
            // so the `TerminalViewDelegate` default extension (compat
            // shim) remains satisfied without double-writing to the
            // pasteboard.
        }

        func oscClipboardWriteRequest(source: TerminalView, request: ClipboardWriteRequest) {
            // Same hardened policy as SSH terminal sessions: foreground
            // gate, 100 KiB cap, settings toggle (default ON), malformed
            // base64 surfaces as a typed diagnostic. Reads stay denied
            // at the fork's `clipboardRead` default and never reach this
            // layer.
            let settings = parent.osc52Settings
            let label = parent.osc52SourceLabel
            let isForeground = parent.osc52ForegroundCheck ?? { true }
            let presenter = parent.osc52ToastPresenter
            let recorder = parent.osc52DenialRecorder
            let outcome = MainActor.assumeIsolated {
                Osc52Router(
                    settings: settings,
                    isForeground: isForeground
                )
                .evaluate(request, sourceLabel: label)
            }
            MainActor.assumeIsolated {
                switch outcome.decision {
                case .write(_, let bytes):
                    presenter?(Osc52ClipboardToast(kind: .copied(bytes: bytes), sourceLabel: outcome.sourceLabel))
                case .clear:
                    presenter?(Osc52ClipboardToast(kind: .cleared, sourceLabel: outcome.sourceLabel))
                case .deny(let reason):
                    #if DEBUG
                    Osc52ClipboardSink.recordDenial(reason)
                    #endif
                    recorder?(reason)
                }
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
