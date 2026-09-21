import XCTest
#if os(iOS)
import UIKit
#endif
@testable import SwiftTerm

// BICTERM-PATCH hunks 13-14 regression coverage: touch-type-aware link
// activation (hunk 13, iOS) and semicolon-safe OSC 8 payload parsing
// (hunk 14, shared). Mirrors the BicTermMouseTests conventions: policy is
// pinned through the real view/terminal paths with deterministic fake
// gesture recognizers, never private UIKit event APIs.
final class BicTermLinkTests: XCTestCase {
    // MARK: - OSC 8 payload parsing (hunk 14)

    #if os(macOS) || os(iOS)
    // A params-prefixed payload keeps the complete URI: semicolons are
    // legal URI characters, so only the FIRST semicolon separates the
    // colon-delimited key:value params from the URI.
    func testUrlAndParamsFromPreservesSemicolonsInUri() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let result = view.urlAndParamsFrom(payload: "id=example;https://example.com/a;b")
        XCTAssertEqual(result?.0, "https://example.com/a;b")
        XCTAssertEqual(result?.1, ["id": "example"])
    }

    // Empty params (the common `OSC 8 ; ; URI` form) still parse.
    func testUrlAndParamsFromEmptyParamsKeepsUri() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let result = view.urlAndParamsFrom(payload: ";https://example.com")
        XCTAssertEqual(result?.0, "https://example.com")
        XCTAssertEqual(result?.1, [:])
    }

    // No separator at all: no URL can be extracted.
    func testUrlAndParamsFromWithoutSeparatorReturnsNil() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        XCTAssertNil(view.urlAndParamsFrom(payload: "https://example.com"))
    }

    // Inherent grammar limitation, pinned: a bare semicolon-containing URI
    // WITHOUT the params separator is indistinguishable from `params;URI`
    // by any single-split parser — the first semicolon is always the
    // separator, so the tail after it is treated as the URI. Emitters must
    // send the (possibly empty) params field: `OSC 8 ; ; URI ST`.
    func testUrlAndParamsFromBareSemicolonUriRemainsAmbiguous() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let result = view.urlAndParamsFrom(payload: "https://example.com/a;b")
        XCTAssertEqual(result?.0, "b")
        XCTAssertEqual(result?.1, [:])
    }
    #endif

    // MARK: - Touch-type-aware activation (hunk 13, iOS)

    #if os(iOS)
    @MainActor
    private func makeFocusedTerminal() -> (view: TerminalView, delegate: LinkTestDelegate, window: UIWindow) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let delegate = LinkTestDelegate()
        view.terminalDelegate = delegate
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.addSubview(view)
        window.makeKeyAndVisible()
        XCTAssertTrue(
            view.becomeFirstResponder(),
            "singleTap only resolves links while the terminal is first responder"
        )
        return (view, delegate, window)
    }

    private func makeTap(
        on view: TerminalView,
        touchType: UITouch.TouchType?,
        at point: CGPoint
    ) -> LinkTap {
        let tap = LinkTap()
        tap.capturedTouchType = touchType
        tap.tapPoint = point
        view.addGestureRecognizer(tap)
        return tap
    }

    private func cellCenter(_ view: TerminalView, col: Double, row: Double) -> CGPoint {
        CGPoint(
            x: (col + 0.5) * Double(view.cellDimension.width),
            y: (row + 0.5) * Double(view.cellDimension.height)
        )
    }

    // Direct finger taps activate an explicit OSC 8 link with NO prior
    // hover highlight (touch devices have no hover), and the full
    // semicolon-containing URI plus params reach the delegate.
    @MainActor
    func testDirectTouchActivatesExplicitLinkWithoutHover() {
        let (view, delegate, _window) = makeFocusedTerminal()
        view.feed(text: "\u{1b}]8;id=example;https://example.com/a;b\u{7}BicTermLink\u{1b}]8;;\u{7}")
        XCTAssertNil(view.linkHighlightRange, "precondition: no hover highlight")
        let tap = makeTap(on: view, touchType: .direct, at: cellCenter(view, col: 3, row: 0))
        view.singleTap(tap)
        XCTAssertEqual(delegate.openRequests.count, 1)
        XCTAssertEqual(delegate.openRequests.first?.link, "https://example.com/a;b")
        XCTAssertEqual(delegate.openRequests.first?.params, ["id": "example"])
    }

    // Pencil taps activate an implicitly detected URL with NO prior hover
    // highlight; implicit links carry empty params.
    @MainActor
    func testPencilTouchActivatesImplicitLinkWithoutHover() {
        let (view, delegate, _window) = makeFocusedTerminal()
        view.feed(text: "see https://example.com/implicit here")
        XCTAssertNil(view.linkHighlightRange, "precondition: no hover highlight")
        let tap = makeTap(on: view, touchType: .pencil, at: cellCenter(view, col: 10, row: 0))
        view.singleTap(tap)
        XCTAssertEqual(delegate.openRequests.count, 1)
        XCTAssertEqual(delegate.openRequests.first?.link, "https://example.com/implicit")
        XCTAssertEqual(delegate.openRequests.first?.params, [:])
    }

    // Indirect-pointer (trackpad/mouse) taps keep the hover-gated path:
    // no activation without a hover highlight, activation with one.
    @MainActor
    func testIndirectPointerTapStaysHoverGated() {
        let (view, delegate, _window) = makeFocusedTerminal()
        view.feed(text: "\u{1b}]8;;https://example.com/hover\u{7}HoverLink\u{1b}]8;;\u{7}")
        XCTAssertNil(view.linkHighlightRange, "precondition: no hover highlight")
        let tap = makeTap(on: view, touchType: .indirectPointer, at: cellCenter(view, col: 3, row: 0))
        view.singleTap(tap)
        XCTAssertTrue(delegate.openRequests.isEmpty, "indirect-pointer taps must stay hover-gated")

        let match = view.terminal.linkMatch(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        XCTAssertNotNil(match, "precondition: the link must resolve for the hover simulation")
        view.linkHighlightRange = match?.rowRanges
        let hoverTap = makeTap(on: view, touchType: .indirectPointer, at: cellCenter(view, col: 3, row: 0))
        view.singleTap(hoverTap)
        XCTAssertEqual(delegate.openRequests.count, 1)
        XCTAssertEqual(delegate.openRequests.first?.link, "https://example.com/hover")
    }

    // The captured touch type survives until consumed and is cleared by
    // both consumption and `reset()`.
    @MainActor
    func testCapturedTouchTypeClearsOnConsumeAndReset() {
        let tap = TouchTypeTapGestureRecognizer(target: nil, action: nil)
        XCTAssertNil(tap.capturedTouchType)
        tap.capturedTouchType = .direct
        XCTAssertEqual(tap.consumeCapturedTouchType(), .direct)
        XCTAssertNil(tap.capturedTouchType, "consumption clears the captured type")
        XCTAssertNil(tap.consumeCapturedTouchType(), "a second consume reads nothing")
        tap.capturedTouchType = .pencil
        tap.reset()
        XCTAssertNil(tap.capturedTouchType, "reset() clears the captured type")
    }
    #endif
}

#if os(iOS)
private final class LinkTestDelegate: TerminalViewDelegate {
    private(set) var openRequests: [(link: String, params: [String: String])] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openRequests.append((link, params))
    }
}

// BICTERM-PATCH hunk 13: deterministic UIKit inputs without private
// event APIs (same discipline as BicTermMouseTests' SelectionTap).
private final class LinkTap: TouchTypeTapGestureRecognizer {
    var tapPoint = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { }
    }
    override func location(in view: UIView?) -> CGPoint { tapPoint }
}
#endif
