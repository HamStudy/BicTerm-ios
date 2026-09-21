import XCTest

/// t4 multi-line paste preview on the REAL app surface: a fixture SSH
/// session (Alpha, hop1 12222) at a `cat -v` prompt. The test writes two
/// lines to the system pasteboard, triggers the terminal's edit-menu
/// Paste, and asserts the confirmation sheet appears; CANCEL must send
/// zero bytes (nothing reaches the remote tail), while PASTE delivers
/// exactly both captured lines. The failure case forces DECSET 2004 on
/// the remote shell first: a multi-line paste then BYPASSES the sheet
/// and arrives bracket-framed (SwiftTerm's direct delivery).
@MainActor
final class PastePreviewUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app.state != .notRunning {
            app.terminate()
        }
        super.tearDown()
    }

    private static let readyMarker = "__PASTE_READY__"
    private static let lineOne = "PASTE_LINE_ONE"
    private static let lineTwo = "PASTE_LINE_TWO"

    /// `cat -v` echoes pasted bytes back through the remote so the raw
    /// scene tail proves exactly what was delivered. `stty -echo` keeps
    /// the shell from double-echoing; `unsetopt nomatch` keeps zsh's
    /// globbing away from the escaped printf markers.
    private func launchSession(command: String) {
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
            "--uitest-session-command", command,
        ]
        app.launch()
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let tail = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tail, contains: Self.readyMarker, timeout: 60))
    }

    private func triggerPasteThroughEditMenu() {
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
    }

    private var sheet: XCUIElement {
        app.descendants(matching: .any)["paste-confirmation-sheet"].firstMatch
    }

    private var tail: String {
        app.staticTexts["scene-tail-Alpha"].label
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

    func testMultiLinePasteRequiresConfirmationAndDeliversExactlyCapturedLines() {
        launchSession(
            command: "unsetopt nomatch; stty -isig -icanon -echo; printf __PASTE_READY__\\\\n; cat -v"
        )

        UIPasteboard.general.string = "\(Self.lineOne)\n\(Self.lineTwo)\n"

        // CANCEL sends nothing.
        triggerPasteThroughEditMenu()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "multi-line paste must present the confirmation sheet")
        XCTAssertTrue(
            app.descendants(matching: .any)["paste-confirm-count"].firstMatch.label.contains("2 lines"),
            "the sheet must report the captured line count"
        )
        app.buttons["paste-confirm-cancel"].firstMatch.tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "cancel must dismiss the sheet")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(
            tail.contains(Self.lineOne),
            "cancel must send zero bytes (tail: \(tail.suffix(200)))"
        )

        // PASTE delivers exactly the captured lines.
        triggerPasteThroughEditMenu()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        app.buttons["paste-confirm-paste"].firstMatch.tap()
        let tailElement = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineOne, timeout: 20))
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineTwo, timeout: 20))
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "a confirmed delivery must dismiss the sheet")
    }

    func testBracketedPasteModeBypassesSheetAndArrivesFramed() {
        // DECSET 2004 ON before the shell prompt: the paste must keep
        // SwiftTerm's direct bracketed delivery (no sheet), and cat -v
        // renders the framing markers as ^[[200~ / ^[[201~.
        launchSession(
            command: "unsetopt nomatch; stty -isig -icanon -echo; printf \\\\033\\\\133?2004h; printf __PASTE_READY__\\\\n; cat -v"
        )

        UIPasteboard.general.string = "\(Self.lineOne)\n\(Self.lineTwo)\n"

        triggerPasteThroughEditMenu()
        XCTAssertFalse(
            sheet.waitForExistence(timeout: 3),
            "bracketed paste must bypass the preview sheet (tail: \(tail.suffix(200)))"
        )

        let tailElement = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(tailElement, contains: "^[[200~", timeout: 20))
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineOne, timeout: 20))
        XCTAssertTrue(waitFor(tailElement, contains: Self.lineTwo, timeout: 20))
        XCTAssertTrue(waitFor(tailElement, contains: "^[[201~", timeout: 20))
    }
}
