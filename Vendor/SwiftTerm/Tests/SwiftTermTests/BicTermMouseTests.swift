import XCTest
#if os(iOS)
import UIKit
#endif
@testable import SwiftTerm

final class BicTermMouseTests: XCTestCase {
    // BICTERM-PATCH hunk 9: exercise the view feed path, not just the emulator.
    #if os(macOS) || os(iOS)
    @MainActor func testFeedPreservesSelectionWhenMouseModeIsOff() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.allowMouseReporting = true
        view.feed(text: "hello world")
        view.selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: view.terminal.displayBuffer)
        XCTAssertTrue(view.selection.active)
        view.feed(text: " more")
        view.feed(byteArray: Array(" output".utf8)[...])
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.getSelectedText(), "hello")
    }

    @MainActor func testFeedClearsSelectionWhenMouseModeIsOn() {
        for mode in [9, 1000, 1002, 1003] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
            view.allowMouseReporting = true
            view.feed(text: "hello world\u{1b}[?\(mode)h")
            view.selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: view.terminal.displayBuffer)
            XCTAssertTrue(view.selection.active)
            view.feed(text: " more")
            XCTAssertFalse(view.selection.active)
        }
    }
    #endif

    #if os(iOS)
    @MainActor func testOptionTapSelectsLocallyEvenWithShiftCapture() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.allowMouseReporting = true
        view.feed(text: "hello world\u{1b}[?1003h\u{1b}[>1s")
        XCTAssertTrue(view.terminal.mouseShiftCapture)
        let tap = SelectionTap()
        view.addGestureRecognizer(tap)
        view.doubleTap(tap)
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.getSelectedText(), "hello")
    }

    @MainActor func testDragAwayFromHandlesSeedsPivot() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: "hello world")
        view.selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: view.terminal.displayBuffer)
        view.selection.selectionMode = .character
        let anchor = view.selection.start
        let pan = SelectionPan()
        view.addGestureRecognizer(pan)
        pan.point = CGPoint(x: 20 * view.cellDimension.width, y: 4 * view.cellDimension.height)
        view.panSelectionHandler(pan)
        XCTAssertEqual(view.selection.pivot, anchor)
        pan.phase = .changed
        pan.point.x += view.cellDimension.width
        view.panSelectionHandler(pan)
        XCTAssertEqual(view.selection.start, anchor)
        XCTAssertEqual(view.selection.end, view.calculateTapHit(gesture: pan).grid)
    }
    #endif

    func testTrackingModeEventGates() {
        let modes: [(Terminal.MouseMode, Bool, Bool, Bool, Bool)] = [
            (.off, false, false, false, false),
            (.x10, true, false, false, false),
            (.vt200, true, true, false, false),
            (.buttonEventTracking, true, true, true, false),
            (.anyEvent, true, true, true, true)
        ]
        for (mode, press, release, drag, hover) in modes {
            XCTAssertEqual(mode.sendButtonPress(), press)
            XCTAssertEqual(mode.sendButtonRelease(), release)
            XCTAssertEqual(mode.sendButtonTracking(), drag)
            XCTAssertEqual(mode.sendMotionEvent(), hover)
        }
    }

    func testSGRPressReleaseDragHoverAndWheel() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        let press = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
        let release = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: press, x: 4, y: 2)
        terminal.sendEvent(buttonFlags: release, x: 4, y: 2)
        terminal.sendMotion(buttonFlags: press, x: 5, y: 2, pixelX: 50, pixelY: 20)
        terminal.sendMotion(buttonFlags: release, x: 6, y: 2, pixelX: 60, pixelY: 20)
        for button in [4, 5] {
            let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: 4, y: 2)
        }
        XCTAssertEqual(delegate.sentData.map { String(decoding: $0, as: UTF8.self) }, [
            "\u{1b}[<0;5;3M", "\u{1b}[<0;5;3m", "\u{1b}[<32;6;3M",
            "\u{1b}[<35;7;3M", "\u{1b}[<64;5;3M", "\u{1b}[<65;5;3M"
        ])
    }

    func testLegacyCoordinatesAndModifiers() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1000h")
        let flags = terminal.encodeButton(button: 0, release: false, shift: true, meta: true, control: true)
        terminal.sendEvent(buttonFlags: flags, x: 0, y: 0)
        XCTAssertEqual(delegate.sentData, [[27, 91, 77, 60, 33, 33]])
        terminal.feed(text: "\u{1b}[?9h")
        XCTAssertEqual(terminal.encodeButton(button: 0, release: false, shift: true, meta: true, control: true), 0)
    }
}

#if os(iOS)
// BICTERM-PATCH hunk 9: deterministic UIKit inputs without private event APIs.
private final class SelectionTap: UITapGestureRecognizer {
    override var modifierFlags: UIKeyModifierFlags { [.alternate, .shift] }
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { }
    }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 1, y: 1) }
}

private final class SelectionPan: UIPanGestureRecognizer {
    var point = CGPoint.zero
    var phase: UIGestureRecognizer.State = .began
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}
#endif
