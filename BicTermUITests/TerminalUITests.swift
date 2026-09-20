import XCTest

/// T12 terminal view UI tests against the loopback fixture sshd (hop1,
/// 127.0.0.1:12222) via the launch-argument-gated TerminalPreviewScreen.
///
/// Each test isolates its own SSH session: `setUp` clears any previously
/// running app process and rebuilds the `XCUIApplication` with
/// `-uitest-terminal-preview` plus a fresh `-uitest-session-id` so the
/// `TerminalPreviewController` tears down any prior transport and starts
/// a new one. `tearDown` restores device orientation and terminates
/// the app, ensuring fixture-side state (zsh prompt, `cat -v`, etc.)
/// from one test does not leak into the next.
@MainActor
final class TerminalUITests: XCTestCase {
    var app: XCUIApplication!
    private static var sessionCounter: Int = 0
    private var sessionID: Int = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Each test gets a unique session id so the controller can
        // detect a stale run() task even when the prior app process
        // hasn't fully torn down by the time the next test starts.
        Self.sessionCounter += 1
        sessionID = Self.sessionCounter
        app = XCUIApplication()
    }

    override func tearDown() {
        // Reset device orientation to portrait for the next test.
        XCUIDevice.shared.orientation = .portrait
        // Tear the app down explicitly so its SSH transport closes
        // and the next test starts against a clean fixture-side state.
        if app.state != .notRunning {
            app.terminate()
        }
        super.tearDown()
    }

    // MARK: - Harness

    private func launchPreview(command: String?, hwkeys: String? = nil) {
        var arguments = [
            "-uitest-terminal-preview",
            "-uitest-session-id", String(sessionID),
        ]
        if let command {
            arguments += ["-uitest-command", command]
        }
        if let hwkeys {
            arguments += ["--uitest-hwkeys", hwkeys]
        }
        app.launchArguments = arguments
        app.launch()
        focusTerminal()
        waitForState("ready", timeout: 40)
    }

    private func focusTerminal() {
    }

    @discardableResult
    private func waitForState(_ state: String, timeout: TimeInterval) -> Bool {
        waitFor(app.staticTexts["previewState"], contains: state, timeout: timeout)
    }

    @discardableResult
    private func waitForTail(_ fragment: String, timeout: TimeInterval = 20, caseInsensitive: Bool = false) -> Bool {
        waitFor(app.staticTexts["previewTail"], contains: fragment, timeout: timeout, caseInsensitive: caseInsensitive)
    }

    @discardableResult
    private func waitForTail(matching pattern: String, timeout: TimeInterval = 20) -> Bool {
        let element = app.staticTexts["previewTail"]
        let predicate = NSPredicate(format: "label MATCHES %@", ".*\(pattern).*")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("timed out waiting for \(element) to match \(pattern.debugDescription); current: \(element.label.suffix(400).debugDescription)")
            return false
        }
        return true
    }

    private func waitFor(
        _ element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval,
        caseInsensitive: Bool = false
    ) -> Bool {
        let format = caseInsensitive ? "label CONTAINS[c] %@" : "label CONTAINS %@"
        let predicate = NSPredicate(format: format, fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("timed out waiting for \(element) to contain \(fragment.debugDescription); current: \(element.label.suffix(400).debugDescription)")
            return false
        }
        return true
    }

    private var tail: String {
        app.staticTexts["previewTail"].label
    }

    // MARK: - Hardware keyboard (plan QA: exact byte sequences via cat -v)

    /// Regression test for the SwiftTerm auto-repeat Timer stall. Before
    /// the vendored fork widened `keyRepeat` to `public` and
    /// `pressesEnded` to `open override`, the `TerminalContainerView`
    /// could not chase-invalidate the Timer that `pressesBegan`
    /// schedules. XCUI's `typeKey` synthesizes only `pressesBegan`,
    /// so the Timer kept firing every 100 ms and the run loop never
    /// idled — `_XCTPerformOnMainRunLoop` hit its 60-second timeout
    /// per key. This test asserts that a single keypress lets
    /// `app.typeKey` + idle-wait complete in well under that budget,
    /// and that the byte arrives at the remote sshd.
    func testSingleKeypressResolvesToIdleQuickly() throws {
        launchPreview(command: "stty -isig -icanon -echo; printf '__GO__\\n'; cat -v")
        waitForTail("__GO__")

        let beforeTail = tail
        let start = Date()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForTail("^[[B", timeout: 5),
            "Down arrow must reach the remote as ESC [ B within 5 s (tail: \(tail.suffix(200)))"
        )
        XCTAssertNotEqual(beforeTail, tail, "tail must change after a single typeKey")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 5.0,
            "a single typeKey + idle-wait must finish in <5 s (took \(elapsed) s); 60 s indicates the auto-repeat Timer is still alive"
        )
    }

    func testHardwareKeyboardControlAndMetaKeys() {
        // XCUIApplication.typeKey cannot synthesize this probe set on the
        // simulator: Escape/Home/End/PageUp/PageDown never reach the app's
        // pressesBegan and the first Control modifier is dropped (T12
        // runtime discrimination, .sisyphus/journal/t12/debug-journal.md).
        // The DEBUG-only --uitest-hwkeys seam has the app itself synthesize
        // real UIKey/UIPress instances and deliver them through the SAME
        // pressesBegan -> SwiftTerm encoder -> SSH transport path, so the
        // byte assertions below remain the acceptance criteria.
        //
        // The command flips the terminal into application-cursor mode
        // (DECCKM, ESC[?1h) 2 s into the session: SwiftTerm (like xterm)
        // treats unmodified PageUp/PageDown as LOCAL scrollback while
        // applicationCursor == false, so CSI 5~/6~ are only encodable once
        // the remote has enabled the mode. The injector splits around an
        // explicit await:decckm marker step; arrows/Home/End are injected
        // first (normal mode) and the page keys last (application mode).
        // The launch-argument marshalling strips quotes, so the command is
        // quote-free and expresses ESC as \033 and [ as \133 — a literal [
        // would trip zsh's globbing ("bad pattern") on this fixture shell.
        launchPreview(
            command: "unsetopt nomatch 2>/dev/null; stty -isig -icanon -echo; printf __GO__\\\\n; (sleep 2; printf \\\\033\\\\133?1h) & cat -v",
            hwkeys: "ctrl+c,ctrl+d,esc,tab,meta+b,home,end,down,left,right,opt+left,opt+right,cmd+left,cmd+right,up,up,up,up,await:decckm,pageup,pagedown"
        )
        waitForTail("__GO__")

        waitForTail("^C^D", timeout: 10)
        waitForTail("^[[5~", timeout: 15)
        let echoed = tail
        print("T12 keyboard probe tail: \(echoed.suffix(300))")
        XCTAssertTrue(echoed.contains("^C"), "Ctrl-C must reach the remote as 0x03")
        XCTAssertTrue(echoed.contains("^D"), "Ctrl-D must reach the remote as 0x04")
        XCTAssertTrue(echoed.contains("^["), "Esc must reach the remote as 0x1b")
        // `cat -v` renders most control bytes as caret notation but keeps
        // TAB and LF raw, so Tab delivery is asserted as the literal 0x09.
        XCTAssertTrue(echoed.contains("\t"), "Tab must reach the remote as 0x09")
        XCTAssertEqual(
            echoed.components(separatedBy: "^[b").count - 1, 2,
            "Option-b and option+left must both arrive as ESC b (word back)"
        )
        XCTAssertTrue(echoed.contains("^[f"), "Option+right must arrive as ESC f (word forward)")
        let upCount = echoed.components(separatedBy: "^[[A").count - 1
        XCTAssertEqual(upCount, 4, "every repeated Up press must be delivered (got \(upCount) of 4; tail: \(echoed.suffix(300)))")
        XCTAssertTrue(echoed.contains("^[[B"), "Down arrow must arrive as ESC [ B")
        XCTAssertTrue(echoed.contains("^[[D"), "Left arrow must arrive as ESC [ D")
        XCTAssertTrue(echoed.contains("^[[C"), "Right arrow must arrive as ESC [ C")
        XCTAssertEqual(
            echoed.components(separatedBy: "^[[H").count - 1, 2,
            "Home and cmd+left must both arrive as ESC [ H (line start)"
        )
        XCTAssertEqual(
            echoed.components(separatedBy: "^[[F").count - 1, 2,
            "End and cmd+right must both arrive as ESC [ F (line end)"
        )
        XCTAssertTrue(echoed.contains("^[[5~"), "PageUp must arrive as ESC [ 5 ~")
        XCTAssertTrue(echoed.contains("^[[6~"), "PageDown must arrive as ESC [ 6 ~")
    }

    // MARK: - CJK / IME

    func testCJKCompositionDeliveredIntact() {
        launchPreview(command: "stty -isig -icanon -echo; printf '__GO__\\n'; cat")
        waitForTail("__GO__")
        // Give the SwiftUI hosting view time to settle focus before
        // issuing typeText. The interposer (removed in the final state)
        // would benefit from a longer settle, but the system keyboard
        // install itself is enough — its responder acquisition is
        // complete by the time the SSH __GO__ echo reaches the tail.
        Thread.sleep(forTimeInterval: 0.25)
        app.typeText("こんにちは世界")

        waitForTail("こんにちは世界", timeout: 15)
    }

    // MARK: - Resize propagation

    func testRotationPropagatesTerminalSizeToRemote() {
        launchPreview(command: "while :; do printf 'SZ:'; stty size; sleep 0.4; done")
        waitForTail(matching: #"SZ:\d+ \d+"#)

        // stty size prints "rows cols".
        let initialMatch = tail.range(of: #"SZ:(\d+) (\d+)"#, options: .regularExpression)
        XCTAssertNotNil(initialMatch, "expected an initial SZ line, tail: \(tail.suffix(200))")
        let initialSize = initialMatch.map { String(tail[$0]) }

        let dimsLabel = app.staticTexts["previewDims"]
        let portraitDims = dimsLabel.label
        XCUIDevice.shared.orientation = .landscapeLeft

        let rotationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", portraitDims),
            object: dimsLabel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotationExpectation], timeout: 20), .completed,
                       "dims label should change after rotation; was \(portraitDims), now \(dimsLabel.label)")

        // previewDims is "cols x rows" — flip when building the expected
        // remote "rows cols" pair.
        let dimsParts = dimsLabel.label
            .replacingOccurrences(of: "dims:", with: "")
            .split(separator: "x")
        XCTAssertEqual(dimsParts.count, 2, "unexpected dims label: \(dimsLabel.label)")
        let cols = Int(dimsParts[0]) ?? 0
        let rows = Int(dimsParts[1]) ?? 0
        XCTAssertGreaterThan(cols, 0)
        XCTAssertGreaterThan(rows, 0)

        waitForTail("SZ:\(rows) \(cols)", timeout: 20)

        if let initialSize {
            XCTAssertNotEqual(initialSize, "SZ:\(rows) \(cols)", "remote stty size must reflect the rotation")
        }
    }

    // MARK: - Full-screen TUI rendering

    func testHtopRendersFullscreenTUI() {
        launchPreview(command: "command -v htop >/dev/null 2>&1 && exec htop || exec top")
        waitForTail("cpu", timeout: 25, caseInsensitive: true)
        attachScreenshot(named: "task-12-htop")
    }

    func testVimRendersFullscreenTUI() {
        launchPreview(command: "exec vim -Nu NONE -n -c 'set laststatus=2 statusline=VIM'")
        waitForTail("VIM", timeout: 25)
        attachScreenshot(named: "task-12-vim")
    }

    func testMouseReportingReachesSSH() {
        launchPreview(command: #"unsetopt nomatch; stty -isig -icanon -echo; printf \\033\\133?1002h\\033\\133?1006h__MOUSE__\\n; cat -v"#)
        waitForTail("__MOUSE__")
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitForTail("^[[<0;")
        waitForTail("^[[<32;")
        XCTAssertNotNil(tail.range(of: #"\^\[\[<0;\d+;\d+m"#, options: .regularExpression))
        attachScreenshot(named: "mouse-sgr-ssh")
    }

    func testMouseReportingDoesNotSurviveSessionReconnect() {
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
            "--uitest-session-command",
            #"unsetopt nomatch; stty -isig -icanon -echo; printf \\033\\133?1003h\\033\\133?1006h__MOUSE_READY__\\n; dd bs=1 count=1 2>/dev/null | od -An -tu1; exit"#,
        ]
        app.launch()
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let output = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(waitFor(output, contains: "__MOUSE_READY__", timeout: 20))
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(waitFor(status, contains: "status:disconnected", timeout: 30))
        app.buttons["scene-reconnect-Alpha"].tap()
        XCTAssertTrue(waitFor(status, contains: "status:active", timeout: 30))
        terminal.tap()
        app.typeText("stty -echo -icanon; printf '__NEW''_SHELL__\\n'; cat -v\n")
        XCTAssertTrue(waitFor(output, contains: "__NEW_SHELL__", timeout: 20))
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1)
        let received = output.label.components(separatedBy: "__NEW_SHELL__").last ?? ""
        XCTAssertFalse(received.contains("^["), "mouse bytes leaked into the new shell: \(received)")
        attachScreenshot(named: "mouse-after-session-reconnect")
    }

    func testLocalSelectionCopyAndPaste() {
        launchPreview(command: #"unsetopt nomatch; stty -isig -icanon -echo; printf \\033\\1332J\\033\\133HCOPYME; cat -v"#)
        waitForTail("COPYME")
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let word = terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: 8))
        word.doubleTap()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(named: "mouse-local-selection")
        copy.tap()
        word.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        waitForTail("COPYMECOPYME")
        attachScreenshot(named: "mouse-local-paste-ssh")
    }

    func testMouseClickMovesVimCursor() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
        launchPreview(command: "exec vim -Nu NONE -n -i NONE -R -c set\\ mouse=a\\ ttymouse=sgr\\ nowrap -c set\\ laststatus=2\\ statusline=MOUSE_ROW_%l \(root)/README.md")
        waitForTail("MOUSE_ROW_1")
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let rows = Double(app.staticTexts["previewDims"].label.split(separator: "x").last ?? "0") ?? 0
        XCTAssertGreaterThan(rows, 10)
        let beforeClick = tail
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 9.5 / rows)).tap()
        waitForTail("\u{1b}[10;1H")
        XCTAssertNotEqual(tail, beforeClick)
        attachScreenshot(named: "mouse-vim-row-10")
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
