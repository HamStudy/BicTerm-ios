import UIKit
import XCTest
@testable import BicTerm
import SwiftTerm

/// K3: the session surface's touch copy/paste mechanics at the view
/// level. The full gesture flow (double-tap → edit menu → Copy) is
/// covered on the preview surface by
/// `TerminalUITests.testLocalSelectionCopyAndPaste`; the session-surface
/// variant of that UI test hangs XCUI's idle detection for pre-existing
/// reasons (see TerminalStripPasteUITests' skip note), so the session
/// view's copy path is verified here.
@MainActor
final class TerminalCopyPasteTests: XCTestCase {
    private func makeTerminalView() -> TerminalContainerView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let view = TerminalContainerView(
            frame: window.bounds,
            font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            options: TerminalOptions(
                cols: 80,
                rows: 24,
                cursorStyle: .steadyBlock,
                scrollback: 100
            )
        )
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return view
    }

    /// copy(_:) puts exactly the selected text on the system pasteboard
    /// and clears the selection.
    func testCopyPutsSelectedTextOnPasteboard() {
        let view = makeTerminalView()
        view.feed(byteArray: Array("COPYWORD_UNIT_TEST\n".utf8)[...])

        view.selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 8, row: 0)
        )
        XCTAssertTrue(view.selection.active)

        view.copy(nil)

        XCTAssertEqual(
            UIPasteboard.general.string, "COPYWORD",
            "copy must deliver exactly the selected text to the pasteboard"
        )
        XCTAssertFalse(view.selection.active, "copy must clear the selection")
    }

    /// paste(_:) with single-line content delivers the pasteboard text
    /// to the terminal's input path (the delegate receives the bytes).
    func testPasteDeliversSingleLineToInput() {
        let view = makeTerminalView()
        let coordinator = PasteCaptureCoordinator()
        view.terminalDelegate = coordinator

        UIPasteboard.general.string = "PASTE_UNIT_TEXT"
        view.paste(nil)

        let delivered = coordinator.sent.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertEqual(
            delivered, "PASTE_UNIT_TEXT",
            "paste must deliver the pasteboard text through the terminal's input path"
        )
    }
}

/// Captures `send(source:data:)` bytes for assertion.
private final class PasteCaptureCoordinator: NSObject, TerminalViewDelegate {
    var sent: [Data] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
}
