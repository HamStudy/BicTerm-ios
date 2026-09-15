import BicTermCore
import Foundation
import SwiftTerm
import SwiftUI
import UIKit

/// Scrollback configuration for every terminal instance (plan T12:
/// bounded in-memory buffer — never persisted to disk).
enum TerminalScrollback {
    /// The documented cap: 10_000 lines of scrollback. At ~1 KB per
    /// full-width line this bounds memory to a few MB per session.
    static let maxLines = 10_000
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`.
///
/// Transport-agnostic by design (T14 wires this into session scenes):
/// it consumes an output byte stream (``SessionRegistry/output(sceneID:)``
/// or a transport's `output`) and reports input bytes and geometry
/// changes through closures. It has NO dependency on any concrete
/// transport type.
///
/// Input path: keyboard bytes arrive on the main thread through
/// SwiftTerm's delegate (`send(source:data:)`) and are handed to
/// ``send`` synchronously. Callers that need async delivery with
/// flow-control backpressure (the T11 `send`/`pipe(input:)` model)
/// should enqueue into their own `AsyncStream` inside the closure and
/// pipe it with `TerminalTransport.pipe(input:)`. Keyboard traffic is
/// human-scale, so a simple unbounded queue is safe in practice.
///
/// Resize path: SwiftTerm computes cols/rows from the view bounds in
/// `layoutSubviews`; geometry changes surface through
/// ``onResize`` — always with cols > 0 and rows > 0 (a 0×0 resize is
/// never propagated; conforming transports ignore zero dimensions as
/// well, per the T11 contract).
struct TerminalRepresentable: UIViewRepresentable {
    /// Bytes FROM the remote. Single consumer: the coordinator's feed
    /// task owns the only iterator for the lifetime of the view.
    let output: AsyncStream<Data>?

    /// Bytes produced by the terminal (keyboard input, bracketed
    /// pastes, mouse reports) toward the session.
    let send: @Sendable (Data) -> Void

    /// Terminal grid geometry changed (bounds, size class, rotation).
    /// Always called with positive cols/rows, on the main thread.
    let onResize: @Sendable (_ cols: Int, _ rows: Int) -> Void

    /// Font point size for the terminal (SF Mono via monospacedSystemFont,
    /// matching the T6 `TerminalTypography` monospaced design). Overridden
    /// by ``fontModel``'s live size when a model is attached.
    var fontSize: CGFloat = 14

    /// Live font-size model: when set, the view starts at the model's size
    /// and a pinch gesture on the terminal zooms the font (persisted,
    /// applied to every surface through the model). Nil in previews/tests
    /// that don't opt in.
    var fontModel: TerminalFontModel? = nil

    /// OSC 52 settings consulted on every remote clipboard write. Defaults
    /// to a shared ``Osc52ClipboardSettings``; previews/tests can inject
    /// one backed by an isolated `UserDefaults` suite.
    var osc52Settings: Osc52ClipboardSettings = Osc52ClipboardSettings()

    /// Optional foreground gate; nil = always foreground (previews/tests
    /// that don't care). The session-scene cache wires the surface's view
    /// to its actual `window != nil`.
    var osc52ForegroundCheck: (@MainActor () -> Bool)? = nil

    var cursorStyle: CursorStyle = .blinkBlock

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(parent: self)
    }

    func makeUIView(context: Context) -> TerminalContainerView {
        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            cursorStyle: cursorStyle,
            scrollback: TerminalScrollback.maxLines
        )
        let resolvedSize = fontModel.map { CGFloat($0.size) } ?? fontSize
        let font = UIFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        view.fontModel = fontModel

        // Hardware keyboard: Option acts as Meta (ESC-prefix) — the T12
        // contract. (SwiftTerm defaults this to true; set explicitly.)
        view.optionAsMetaKey = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
            // UITEST: never install the software keyboard for this surface
            // (SwiftTerm fork hunks 4/5 — hidden blocker input view, no
            // .causesPageTurn trait). UIKit's remote-keyboard window churn
            // around a focused text-input responder is one of the two
            // drivers of XCTest's 60-second per-interaction idle wait.
            view.installsSoftwareKeyboard = false
        }
        #endif

        view.applyNativeTerminalColors()

        view.terminalDelegate = context.coordinator
        view.accessibilityIdentifier = "terminalView"

        context.coordinator.startFeeding(into: view)
        return view
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: TerminalContainerView, coordinator: TerminalCoordinator) {
        coordinator.stopFeeding()
        uiView.delegate = nil
        uiView.updateUiClosed()
    }
}

/// Coordinator: bridges SwiftTerm's `TerminalViewDelegate` to the
/// closures above and pumps the remote output stream into the view.
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    var parent: TerminalRepresentable

    /// Feeds remote output chunks into the terminal on the main thread.
    private var feedTask: Task<Void, Never>?

    init(parent: TerminalRepresentable) {
        self.parent = parent
        super.init()
    }

    func startFeeding(into view: TerminalContainerView) {
        feedTask?.cancel()
        guard let output = parent.output else { return }
        feedTask = Task { [weak view] in
            for await chunk in output {
                guard let view else { return }
                let slice = Array(chunk)[...]
                await MainActor.run {
                    view.feed(byteArray: slice)
                }
            }
        }
    }

    func stopFeeding() {
        feedTask?.cancel()
        feedTask = nil
    }

    // MARK: - TerminalViewDelegate (input side)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Main thread, from SwiftTerm input paths (pressesBegan,
        // insertText/IME commit, paste, mouse reports).
        parent.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // 0×0 (or negative) geometry must NEVER reach the transport —
        // guard here, before the caller's resize path.
        guard newCols > 0, newRows > 0 else { return }
        parent.onResize(newCols, newRows)
    }

    // MARK: - TerminalViewDelegate (cosmetic / optional)

    func setTerminalTitle(source: TerminalView, title: String) {
        // Surfaced by T14's scene chrome; intentionally unused here.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Links are only opened after explicit user confirmation in a
        // later task; ignore for now (never auto-navigate).
    }

    // OSC 52 clipboard WRITE from the remote: legacy byte-level callback,
    // now a no-op. The fork's parse path routes every write attempt
    // through `oscClipboardWriteRequest` (hunk 11) so the host applies
    // the typed policy at one decision point — foreground gating, size
    // cap, settings toggle, malformed-base64 diagnostics. Kept as an
    // override so the `TerminalViewDelegate` default extension (compat
    // shim) remains satisfied without double-writing.
    func clipboardCopy(source: TerminalView, content: Data) {}

    func oscClipboardWriteRequest(source: TerminalView, request: ClipboardWriteRequest) {
        // The standalone `TerminalRepresentable` is DEBUG-only (UITEST
        // preview surfaces). Apply the same hardened policy here as the
        // session/herdr surfaces: foreground gate (nil = always
        // foreground for previews/tests), 100 KiB cap, settings toggle
        // (default ON). An approved write lands on UIPasteboard but
        // there is no scene model to fire a toast on. Production goes
        // through `TerminalSurface` (cache path), which carries the
        // scene-model hook.
        let settings = parent.osc52Settings
        let isForeground = parent.osc52ForegroundCheck ?? { true }
        _ = MainActor.assumeIsolated {
            Osc52Router(
                settings: settings,
                isForeground: isForeground
            )
            .evaluate(request, sourceLabel: "Terminal")
        }
    }
}

/// SwiftTerm `TerminalView` with BicTerm-specific input hardening:
///
/// - Local user-initiated copy/paste uses SwiftTerm's selection and
///   bracketed-paste support. Remote OSC 52 writes remain denied in
///   the coordinator delegate.
/// - Grabs first responder status when attached to a window so a
///   hardware keyboard (UIKey presses) are delivered to the terminal
///   without requiring a tap first.
/// - Pinch-to-zoom on the surface rescales the font through
///   ``TerminalFontModel`` (installed via ``fontModel``; nil keeps the
///   surface fixed-size). SwiftTerm ships no pinch gesture, so nothing
///   conflicts; the vendored fork is untouched.
final class TerminalContainerView: TerminalView {
    /// Installs zoom support. Standalone surfaces edit this model; cached
    /// session surfaces route through `onFontPinch` to preserve window isolation.
    var fontModel: TerminalFontModel? {
        didSet {
            guard fontModel != nil, pinchRecognizer == nil else { return }
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:)))
            addGestureRecognizer(pinch)
            pinchRecognizer = pinch
        }
    }

    private var pinchRecognizer: UIPinchGestureRecognizer?
    /// A session pinch writes its own override, starting from the displayed
    /// font rather than the global model, so zoom never reflows other windows.
    var onFontPinch: (@MainActor (Double) -> Void)?
    /// Point size captured at pinch start; the gesture's absolute scale
    /// multiplies it, so quantization steps the size in 0.5pt increments
    /// as the pinch grows (no per-event re-anchoring needed).
    private var pinchStartSize = TerminalFontSettings.defaultSize

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isFirstResponder {
            becomeFirstResponder()
        }
    }

    /// An appearance change (the app-level theme override applied at the
    /// scene root, or — under System — the device appearance) arrives as a
    /// trait change; re-resolve the native chrome colors for the new style.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle else { return }
        applyNativeTerminalColors()
    }

    /// Re-resolves the surface's native chrome colors (default cell
    /// background/foreground) for the current traits. SwiftTerm snapshots
    /// UIColors into its `Terminal` model on assignment, and `setupOptions`
    /// copied the creation-time background into the view's layer — so
    /// neither follows a scheme change on its own and both are re-applied
    /// here. Foreground first, then background: the background setter is
    /// the one that triggers SwiftTerm's full repaint (`colorsChanged`).
    /// The 16 ANSI palette colors and the cursor are content colors
    /// (remote output semantics) and are deliberately untouched.
    func applyNativeTerminalColors() {
        let palette = TerminalColors.palette(for: traitCollection.userInterfaceStyle)
        nativeForegroundColor = palette.nativeForeground
        nativeBackgroundColor = palette.nativeBackground
        layer.backgroundColor = palette.nativeBackground.cgColor
    }

    /// Main thread (gesture delivery), same actor as the model. Only the
    /// normalized result is written, so inter-step `.changed` events are
    /// cheap no-ops.
    @objc private func handleFontPinch(_ recognizer: UIPinchGestureRecognizer) {
        // TerminalContainerView sits under SwiftTerm's preconcurrency
        // TerminalView, so this @objc callback is statically nonisolated;
        // UIKit delivers gesture actions on the main thread.
        MainActor.assumeIsolated {
            guard let fontModel else { return }
            switch recognizer.state {
            case .began:
                pinchStartSize = font.pointSize
            case .changed:
                let size = pinchStartSize * Double(recognizer.scale)
                if let onFontPinch {
                    onFontPinch(size)
                } else {
                    fontModel.setSize(size)
                }
            default:
                break
            }
        }
    }

    #if DEBUG
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        guard ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") else { return }

        // XCUI typeKey omits the matching pressesEnded event, leaving
        // SwiftTerm's physical-key repeat timer alive indefinitely. Cancel
        // only on the DEBUG preview; Release keeps SwiftTerm's normal
        // pressesBegan-to-pressesEnded auto-repeat lifecycle unchanged.
        keyRepeat?.invalidate()
        keyRepeat = nil
    }
    #endif
}
