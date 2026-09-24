import UIKit
import XCTest

/// Keyboard-free touch paste/copy (K3): while the software keyboard is
/// sticky-hidden, the strip's trailing app slot swaps from the dismiss
/// control to a Paste control that routes through the terminal's
/// existing `paste(_:)` semantics — multi-line pastes present the
/// preview confirmation sheet, single-line pastes deliver directly.
/// Selection copy (double-tap → edit menu → Copy) is verified on iPhone
/// alongside it.
@MainActor
final class TerminalStripPasteUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // The strip's Paste button reads the pasteboard programmatically,
        // so iOS presents the paste-permission alert whenever the
        // pasteboard was written by another app (the test runner here;
        // any other app in production). Allow it so the paste proceeds.
        addUIInterruptionMonitor(withDescription: "paste permission") { alert in
            let allow = alert.buttons["Allow Paste"].firstMatch
            if allow.exists {
                allow.tap()
                return true
            }
            return false
        }
    }

    override func tearDown() {
        if app.state != .notRunning {
            app.terminate()
        }
        super.tearDown()
    }

    private static let readyMarker = "__STRIP_PASTE_READY__"
    private static let lineOne = "STRIP_PASTE_LINE_ONE"
    private static let lineTwo = "STRIP_PASTE_LINE_TWO"

    /// `cat -v` echoes pasted bytes back through the remote so the raw
    /// scene tail proves exactly what was delivered (same harness contract
    /// as PastePreviewUITests). `--uitest-pasteboard` makes the APP write
    /// the pasteboard: same-process writes are exempt from iOS's
    /// paste-permission alert, which a runner-written pasteboard would
    /// present on the strip button's read (and hang XCUI's idle wait).
    private func launchSession(command: String, pasteboard: String? = nil) {
        var arguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
            "--uitest-session-command", command,
        ]
        if let pasteboard {
            arguments += ["--uitest-pasteboard", pasteboard]
        }
        app.launchArguments = arguments
        app.launch()
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let tail = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tail, contains: Self.readyMarker, timeout: 60))
    }

    private var sheet: XCUIElement {
        app.descendants(matching: .any)["paste-confirmation-sheet"].firstMatch
    }

    private var tail: String {
        app.staticTexts["scene-tail-Alpha"].label
    }

    private var dismissButton: XCUIElement {
        app.buttons["terminal-keyboard-dismiss"]
    }

    private var pasteButton: XCUIElement {
        app.buttons["terminal-strip-paste"]
    }

    /// The strip can default hidden on the simulator (the Mac keyboard
    /// bridges as a GCKeyboard): make sure it is explicitly shown.
    private func ensureStripVisible() {
        let accessory = app.descendants(matching: .any)["terminal-accessory"]
        if !accessory.exists {
            let menuButton = app.buttons["scene-menu"].firstMatch
            menuButton.tap()
            let toggle = app.buttons["terminal-toolbar-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "toolbar toggle missing from the session menu")
            toggle.tap()
        }
        XCTAssertTrue(
            accessory.waitForExistence(timeout: 10),
            "the strip must be visible for the strip-slot controls"
        )
    }

    /// The keyboard is up at launch (the terminal focuses on attach);
    /// dismiss it so the paste control takes over the strip slot.
    private func dismissKeyboardForPasteControl() {
        ensureStripVisible()
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 10),
            "dismiss control missing (strip hidden by the hardware-keyboard heuristic?)"
        )
        dismissButton.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )
        XCTAssertTrue(
            pasteButton.waitForExistence(timeout: 5),
            "the paste control must take over the strip slot while the keyboard is sticky-hidden"
        )
        XCTAssertFalse(
            dismissButton.waitForExistence(timeout: 1),
            "the dismiss control must vacate the slot while the keyboard is hidden"
        )
    }

    @discardableResult
    private func waitFor(
        _ element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("timed out waiting for \(element) to contain \(fragment.debugDescription); current: \(element.label.suffix(400).debugDescription)")
            return false
        }
        return true
    }

    // MARK: - Tests

    /// Multi-line pasteboard content through the strip button presents
    /// the preview sheet, and confirming delivers exactly the captured
    /// lines to the remote.
    func testStripPasteRoutesMultiLineThroughPreviewSheet() {
        launchSession(
            command: "unsetopt nomatch; stty -isig -icanon -echo; printf __STRIP_PASTE_READY__\\\\n; cat -v",
            pasteboard: "\(Self.lineOne)\\n\(Self.lineTwo)\\n"
        )

        dismissKeyboardForPasteControl()

        pasteButton.tap()
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 10),
            "a multi-line paste through the strip button must present the confirmation sheet"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["paste-confirm-count"].firstMatch.label.contains("2 lines"),
            "the sheet must report the captured line count"
        )
        app.buttons["paste-confirm-paste"].firstMatch.tap()

        let tailElement = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineOne, timeout: 20))
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineTwo, timeout: 20))
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "a confirmed delivery must dismiss the sheet")
    }

    /// Single-line pasteboard content through the strip button delivers
    /// directly — no preview sheet for a one-line paste.
    func testStripPasteSingleLineDeliversDirectly() {
        launchSession(
            command: "unsetopt nomatch; stty -isig -icanon -echo; printf __STRIP_PASTE_READY__\\\\n; cat -v",
            pasteboard: "STRIP_PASTE_SINGLE_LINE"
        )

        dismissKeyboardForPasteControl()

        pasteButton.tap()
        XCTAssertFalse(
            sheet.waitForExistence(timeout: 3),
            "a single-line paste must not present the confirmation sheet"
        )
        let tailElement = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tailElement, contains: "STRIP_PASTE_SINGLE_LINE", timeout: 20))
    }

    /// Touch copy on the session surface: double-tap selects a word, the
    /// edit menu's Copy lands the selected text on the system pasteboard,
    /// and the edit menu's Paste delivers it back through the terminal's
    /// paste path (single-line: direct delivery, echoed by `cat -v`).
    ///
    /// Regression pin for the session-surface never-idle defect (K3,
    /// issues.md): tapping Copy in this flow used to hang XCUI's
    /// post-tap idle wait forever — the app stayed idle and the copy
    /// completed, but XCUI never observed quiescence. This test runs
    /// the flow with the software keyboard UP (the terminal focuses on
    /// attach); if the never-idle regression returns, the Copy tap
    /// hangs here. The preview surface's twin is
    /// TerminalUITests.testLocalSelectionCopyAndPaste.
    ///
    /// NOT COVERED: the keyboard-FREE variant (keyboard sticky-hidden
    /// first) is blocked by a separate defect chain — see the 2026-09-24
    /// entry in .omo/notepads/ssh-key-pool/issues.md: SwiftUI squeezes
    /// the terminal host by the keyboard inset AT dismissal and the
    /// recovery pass is unreliable, so the double-tap's re-focus
    /// triggers a large grid resize that clears the selection
    /// (upstream processSizeChange) and drops the edit menu.
    func testSelectionCopyViaDoubleTapEditMenu() {
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
            "--uitest-session-command",
            #"unsetopt nomatch; stty -isig -icanon -echo; printf \\033\\1332J\\033\\133HCOPYME; cat -v"#,
        ]
        app.launch()
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(
            waitFor(app.staticTexts["scene-tail-Alpha"], contains: "COPYME", timeout: 60),
            "the session must echo COPYME before selecting it"
        )

        // The software keyboard is up at launch (the terminal focuses on
        // attach) — the configuration the never-idle defect was
        // reproduced in.
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let word = terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: 8))
        word.doubleTap()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)

        copy.tap()

        word.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        XCTAssertTrue(
            waitFor(app.staticTexts["scene-tail-Alpha"], contains: "COPYMECOPYME", timeout: 20),
            "the copied word must paste back and echo through cat -v"
        )
    }
}
