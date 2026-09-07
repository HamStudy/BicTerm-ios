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

    private func launchPreview(command: String?) {
        var arguments = [
            "-uitest-terminal-preview",
            "-uitest-session-id", String(sessionID),
        ]
        if let command {
            arguments += ["-uitest-command", command]
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
        launchPreview(command: "stty -isig -icanon -echo; printf '__GO__\\n'; cat -v")
        waitForTail("__GO__")

        app.typeKey("c", modifierFlags: .control)
        app.typeKey("d", modifierFlags: .control)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("b", modifierFlags: .option)
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.end, modifierFlags: [])
        app.typeKey(.pageUp, modifierFlags: [])
        app.typeKey(.pageDown, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        // Repeat delivery: four further Up presses must EACH reach the
        // remote (system key auto-repeat feeds the same pressesBegan
        // path; every repeat event must survive to the pty).
        for _ in 0..<4 {
            app.typeKey(.upArrow, modifierFlags: [])
        }

        waitForTail("^C^D", timeout: 10)
        waitForTail("^[[5~", timeout: 10)
        let echoed = tail
        print("T12 keyboard probe tail: \(echoed.suffix(300))")
        XCTAssertTrue(echoed.contains("^C"), "Ctrl-C must reach the remote as 0x03")
        XCTAssertTrue(echoed.contains("^D"), "Ctrl-D must reach the remote as 0x04")
        XCTAssertTrue(echoed.contains("^["), "Esc must reach the remote as 0x1b")
        XCTAssertTrue(echoed.contains("^I"), "Tab must reach the remote as 0x09")
        XCTAssertTrue(echoed.contains("^[b"), "Option-b (optionAsMetaKey) must arrive as ESC b")
        let upCount = echoed.components(separatedBy: "^[[A").count - 1
        XCTAssertEqual(upCount, 5, "every repeated Up press must be delivered (got \(upCount) of 5; tail: \(echoed.suffix(300)))")
        XCTAssertTrue(echoed.contains("^[[B"), "Down arrow must arrive as ESC [ B")
        XCTAssertTrue(echoed.contains("^[[D"), "Left arrow must arrive as ESC [ D")
        XCTAssertTrue(echoed.contains("^[[C"), "Right arrow must arrive as ESC [ C")
        XCTAssertTrue(echoed.contains("^[[5~"), "PageUp must arrive as ESC [ 5 ~")
        XCTAssertTrue(echoed.contains("^[[6~"), "PageDown must arrive as ESC [ 6 ~")
        XCTAssertTrue(echoed.contains("^[[H") || echoed.contains("^[[1~") || echoed.contains("^[[F") || echoed.contains("^[[4~"),
            "Home/End must arrive as escape sequences (got: \(echoed.suffix(200)))")
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

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
