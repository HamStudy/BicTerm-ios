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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> TerminalContainerView {
        let resolvedSize = fontModel.map { CGFloat($0.size) } ?? 14
        let font = UIFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        // 80×24 placeholder grid: the real geometry arrives with the first
        // layout, which resizes the embedded client before the first paint.
        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            cursorStyle: .blinkBlock,
            scrollback: TerminalScrollback.maxLines
        )
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        view.fontModel = fontModel
        view.optionAsMetaKey = true
        view.applyNativeTerminalColors()
        view.terminalDelegate = context.coordinator
        view.accessibilityIdentifier = "herdr-embed-tui"
        context.coordinator.startFeeding(into: view, runtime: runtime)
        return view
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {
        context.coordinator.parent = self
        if let liveSize = fontModel?.size, uiView.font.pointSize != CGFloat(liveSize) {
            uiView.font = UIFont.monospacedSystemFont(ofSize: CGFloat(liveSize), weight: .regular)
        }
    }

    static func dismantleUIView(_ uiView: TerminalContainerView, coordinator: Coordinator) {
        coordinator.stopFeeding()
        uiView.delegate = nil
        uiView.updateUiClosed()
    }

    /// SwiftTerm delegate: input toward the embedded client, geometry toward
    /// the pty window. Remote clipboard writes (OSC 52) stay denied, exactly
    /// like SSH terminal sessions.
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

        func clipboardCopy(source: TerminalView, content: Data) {}

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
