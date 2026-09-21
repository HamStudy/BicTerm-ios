import XCTest

/// OSC 8 link confirmation on the REAL SSH session surface: the fixture
/// session (hop1 sshd on 12222, pretrusted) prints an OSC 8 hyperlink
/// (clear+home first so the label sits at row 0), a FINGER TAP — XCUI
/// taps are direct touches, no hover — activates it through fork hunk
/// 13, and the scene must present the confirmation sheet with the exact
/// host and the FULL semicolon-containing URL. Cancel dismisses and
/// NOTHING opens (the app stays foreground; Safari never activates). A
/// `file://` link presents with Open disabled.
///
/// Command-driven assertions gate on the payload reaching the scene's
/// raw tail first (the fixture shell's zshrc can delay command
/// execution by tens of seconds under parallel-suite load).
@MainActor
final class TerminalLinkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchSession(command: String) {
        app.launchArguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
            "--uitest-session-command", command,
        ]
        app.launch()

        let sceneTitle = app.descendants(matching: .any)["scene-title-Alpha"]
        XCTAssertTrue(
            sceneTitle.waitForExistence(timeout: 30),
            "the Alpha session scene must open before the command can run"
        )
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(
            waitForLabel(status, contains: "status:active", timeout: 45),
            "the Alpha session must reach active before its command runs"
        )
    }

    private func waitForLabel(
        _ element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private var tail: XCUIElement {
        app.staticTexts["scene-tail-Alpha"]
    }

    private var sheet: XCUIElement {
        app.descendants(matching: .any)["link-confirmation-sheet"]
    }

    /// Taps the middle of the link label, which the printf placed at
    /// row 0 starting at column 0 (clear + home first).
    private func tapLinkLabel() {
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let linkCell = terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 30, dy: 8))
        linkCell.tap()
    }

    func testFingerTapOnOsc8LinkShowsConfirmationAndCancelOpensNothing() {
        // zsh-safe, quote-free form of:
        //   printf '\e[2J\e[H\e]8;;https://example.com/verify;a\aBicTermLink\e]8;;\a'
        // (`\\033`/`\\133` survive the shell for printf as ESC and `[`,
        // `\\073` is the OSC semicolon AND the URI's semicolon — a bare
        // `;` would split the remote shell command.)
        launchSession(
            command: #"printf \\033\\1332J\\033\\133H\\033]8\\073\\073https://example.com/verify\\073a\\aBicTermLink\\033]8\\073\\073\\a"#
        )

        XCTAssertTrue(
            waitForLabel(tail, contains: "BicTermLink", timeout: 45),
            "the OSC 8 link label must reach the session's raw tail — current tail: \(tail.label.suffix(300))"
        )

        tapLinkLabel()

        XCTAssertTrue(
            sheet.waitForExistence(timeout: 10),
            "a direct finger tap on an OSC 8 link must present the confirmation sheet — absence means the sheet is genuinely missing from the AX tree"
        )
        XCTAssertEqual(
            app.staticTexts["link-confirm-host"].label,
            "example.com",
            "the sheet must show the link's host"
        )
        XCTAssertEqual(
            app.staticTexts["link-confirm-url"].label,
            "https://example.com/verify;a",
            "the sheet must show the FULL URL including the semicolon (fork hunk 14)"
        )

        app.buttons["link-confirm-cancel"].tap()
        XCTAssertFalse(
            sheet.waitForExistence(timeout: 5),
            "cancel must dismiss the confirmation sheet"
        )

        // Nothing opened: the app stays foreground and Safari never
        // activates. The grace window only guards against a delayed
        // launch; the cancel path never calls the opener (pinned by the
        // unit tests).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "cancel must leave BicTerm in the foreground")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertNotEqual(safari.state, .runningForeground, "cancel must not open Safari")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "osc8-link-cancel-ax"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFileSchemeLinkPresentsWithOpenDisabled() {
        // zsh-safe form of:
        //   printf '\e[2J\e[H\e]8;;file:///etc/passwd\aPasswdLink\e]8;;\a'
        launchSession(
            command: #"printf \\033\\1332J\\033\\133H\\033]8\\073\\073file:///etc/passwd\\aPasswdLink\\033]8\\073\\073\\a"#
        )

        XCTAssertTrue(
            waitForLabel(tail, contains: "PasswdLink", timeout: 45),
            "the file:// link label must reach the session's raw tail — current tail: \(tail.label.suffix(300))"
        )

        tapLinkLabel()

        let open = app.buttons["link-confirm-open"]
        XCTAssertTrue(
            open.waitForExistence(timeout: 10),
            "a file:// link must still present the confirmation sheet"
        )
        XCTAssertFalse(
            open.isEnabled,
            "Open must be disabled for a file:// link"
        )
        XCTAssertEqual(
            app.staticTexts["link-confirm-url"].label,
            "file:///etc/passwd",
            "the sheet must show the full file:// URL"
        )

        app.buttons["link-confirm-cancel"].tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 5), "cancel must dismiss the sheet")
    }
}
