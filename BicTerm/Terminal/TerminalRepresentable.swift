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
    /// matching the T6 `TerminalTypography` monospaced design).
    var fontSize: CGFloat = 14

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
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let view = TerminalContainerView(frame: .zero, font: font, options: options)

        // Hardware keyboard: Option acts as Meta (ESC-prefix) — the T12
        // contract. (SwiftTerm defaults this to true; set explicitly.)
        view.optionAsMetaKey = true

        view.nativeBackgroundColor = UIColor(red: 0x0D / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0xE6 / 255, green: 0xED / 255, blue: 0xF3 / 255, alpha: 1)

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

    // OSC 52 clipboard WRITE from the remote: denied for v1 — a remote
    // program must never silently overwrite the user's pasteboard.
    // Only the user's own selection copy (`copy:` on the container
    // view) writes to UIPasteboard. Remote reads stay denied via the
    // protocol default (nil).
    func clipboardCopy(source: TerminalView, content: Data) {}
}

/// SwiftTerm `TerminalView` with BicTerm-specific input hardening:
///
/// - Copy-only clipboard: local selection copy writes the pasteboard;
///   the responder `paste` action is neutralized (v1 ships no paste
///   path — plan T12 "copy only"). Remote OSC 52 writes are denied in
///   the coordinator delegate.
/// - Grabs first responder status when attached to a window so a
///   hardware keyboard (UIKey presses) are delivered to the terminal
///   without requiring a tap first.
final class TerminalContainerView: TerminalView {
    // SwiftTerm's canPerformAction is non-open (not overridable
    // cross-module); the paste SELECTOR is therefore blocked at its
    // delivery point instead.
    override func paste(_ sender: Any?) {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isFirstResponder {
            becomeFirstResponder()
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
