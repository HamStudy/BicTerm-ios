import XCTest

/// T17 herdr semantic input UI tests: the DEBUG replay drives the full
/// presentation fence (mode `input`) so the FFI input lane unfreezes, and
/// every assertion reads the on-screen input echo — the same DEBUG surface
/// the unit suite asserts at the model level. All synthesized input goes
/// through the `--uitest-hwkeys` injector (keys via the field's presses
/// overrides, `text:` via per-grapheme insertText — XCUI `typeKey` and
/// `typeText` both no-op against the replay scene despite a live RTI
/// session), starting when the replay reports ready. Both canonical
/// simulators.
final class HerdrInputUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var herdirFixtureDir: String {
        Self.repoRoot.appendingPathComponent("Fixtures/herdr/golden").path
    }

    private var vendorGoldenDir: String {
        Self.repoRoot
            .appendingPathComponent("Vendor/herdr/herdr-protocol/tests/fixtures/golden").path
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Device orientation is sticky across tests; pin it so a leaking
        // rotation test can't put the next launch in landscape.
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchApp(mode: String = "input", hwkeys: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-replay", "--uitest-herdr-mode", mode]
        if let hwkeys {
            app.launchArguments += ["--uitest-hwkeys", hwkeys]
        }
        app.launchEnvironment["HERDR_FIXTURE_DIR"] = herdirFixtureDir
        app.launchEnvironment["HERDR_VENDOR_GOLDEN_DIR"] = vendorGoldenDir
        app.launch()
        return app
    }

    private func waitForReplayReady(_ app: XCUIApplication) {
        let ready = app.descendants(matching: .any)["herdr-replay-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "the fence must fully apply")
    }

    private func echoText(_ app: XCUIApplication) -> String {
        app.staticTexts["herdr-input-echo"].label
    }

    @discardableResult
    private func waitForEcho(
        _ app: XCUIApplication,
        contains needle: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let echo = app.staticTexts["herdr-input-echo"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", needle),
            object: echo
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Text input

    func testTypingRoutesCommittedTextToTheFocusedPane() throws {
        let app = launchApp(hwkeys: "text:hi")
        waitForReplayReady(app)
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-input-field"].exists,
            "the zero-chrome input field is the workspace's first responder"
        )

        // The injector commits one insertText per grapheme (the soft
        // keyboard's own granularity); the model commits each one.
        XCTAssertTrue(
            waitForEcho(app, contains: "text(\"h\"→w1:p2)"),
            "first committed character routes to the snapshot-focused pane (echo: \(echoText(app)))"
        )
        XCTAssertTrue(
            waitForEcho(app, contains: "text(\"i\"→w1:p2)"),
            "second committed character follows (echo: \(echoText(app)))"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-input-note"].exists,
            "a successful send never raises the note strip"
        )
        attachScreenshot(app, name: "herdr-input-typing")
    }

    func testCJKCommitCrossesTheLaneIntact() throws {
        let app = launchApp(hwkeys: "text:こんにちは世界")
        waitForReplayReady(app)

        // Per-grapheme commits, so the first/last character needles
        // bracket the whole string.
        XCTAssertTrue(
            waitForEcho(app, contains: "こ", timeout: 15),
            "the CJK string starts committing (echo: \(echoText(app)))"
        )
        XCTAssertTrue(
            waitForEcho(app, contains: "界\"→w1:p2"),
            "the CJK string commits through the last character (echo: \(echoText(app)))"
        )
    }

    // MARK: - Hardware keys (injector)

    func testSpecialKeysTraverseTheMapperToTheFFI() throws {
        let app = launchApp(
            hwkeys: "esc,home,end,pageup,pagedown,up,down,left,right,ctrl+c"
        )
        waitForReplayReady(app)

        for needle in [
            "key(esc→w1:p2)", "key(home→w1:p2)", "key(end→w1:p2)",
            "key(pageup→w1:p2)", "key(pagedown→w1:p2)",
            "key(up→w1:p2)", "key(down→w1:p2)",
            "key(left→w1:p2)", "key(right→w1:p2)",
            "key(ctrl+c→w1:p2)",
        ] {
            XCTAssertTrue(
                waitForEcho(app, contains: needle, timeout: 15),
                "missing \(needle) (echo: \(echoText(app)))"
            )
        }
        attachScreenshot(app, name: "herdr-input-special-keys")
    }

    // MARK: - Focus

    func testTapPaneRetargetsTheNextCommit() throws {
        let app = launchApp(hwkeys: "await:echo:target(w1:p1),text:q")
        waitForReplayReady(app)

        let pane = app.descendants(matching: .any)["herdr-pane-w1:p1"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()

        XCTAssertTrue(
            waitForEcho(app, contains: "target(w1:p1)"),
            "tap-to-focus records the retarget (echo: \(echoText(app)))"
        )
        let targeted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "input target"),
            object: pane
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [targeted], timeout: 5), .completed,
            "the tapped pane's VoiceOver label gains the input-target marker"
        )

        // The injector holds its commit until the tap's retarget lands in
        // the echo, so the text provably routes to the tapped pane.
        XCTAssertTrue(
            waitForEcho(app, contains: "text(\"q\"→w1:p1)"),
            "the next commit routes to the tapped pane (echo: \(echoText(app)))"
        )
        attachScreenshot(app, name: "herdr-input-tap-focus")
    }

    func testControlShiftArrowsWalkThePaneGrid() throws {
        let app = launchApp(hwkeys: "nav+left,nav+down,nav+right,nav+up")
        waitForReplayReady(app)

        let expected = ["target(w1:p1)", "target(w1:p3)", "target(w1:p4)", "target(w1:p2)"]
        for needle in expected {
            XCTAssertTrue(
                waitForEcho(app, contains: needle, timeout: 15),
                "missing \(needle) (echo: \(echoText(app)))"
            )
        }
        // In-order occurrence, tolerating interleaved lines.
        var position = echoText(app).startIndex
        let finalEcho = echoText(app)
        for needle in expected {
            guard let range = finalEcho.range(of: needle, range: position..<finalEcho.endIndex) else {
                XCTFail("\(needle) out of order (echo: \(finalEcho))")
                return
            }
            position = range.upperBound
        }
        XCTAssertFalse(
            finalEcho.contains("key("),
            "navigation chords are never sent to the pane (echo: \(finalEcho))"
        )
    }

    // MARK: - Frozen window

    func testTypingMidFenceShowsTheFrozenNote() throws {
        // Mode `workspace` commits the surface but never completes the
        // presentation fence, so the FFI input lane stays frozen.
        let app = launchApp(mode: "workspace", hwkeys: "text:hi")
        waitForReplayReady(app)

        XCTAssertTrue(
            waitForEcho(app, contains: "frozen"),
            "the FFI bounce is recorded (echo: \(echoText(app)))"
        )
        let note = app.descendants(matching: .any)["herdr-input-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the note strip surfaces the frozen state")
        XCTAssertEqual(note.label, "Server is still syncing the surface; input held off")
        attachScreenshot(app, name: "herdr-input-frozen-note")
    }

    // MARK: - Resize

    func testRotationSendsLiveResizeThroughTheLane() throws {
        let app = launchApp()
        waitForReplayReady(app)
        defer { XCUIDevice.shared.orientation = .portrait }

        let baseline = resizeCount(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitForResizeCount(app, greaterThan: baseline),
            "rotation reports the new grid through the FFI resize (echo: \(echoText(app)))"
        )

        let landscapeCount = resizeCount(app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitForResizeCount(app, greaterThan: landscapeCount),
            "rotating back sends another resize (echo: \(echoText(app)))"
        )
        attachScreenshot(app, name: "herdr-input-rotation-resize")
    }

    private func resizeCount(_ app: XCUIApplication) -> Int {
        echoText(app).components(separatedBy: "resize(").count - 1
    }

    /// Rotation animations can report intermediate sizes, so assert the
    /// resize count grows rather than matching an exact final count.
    private func waitForResizeCount(
        _ app: XCUIApplication,
        greaterThan threshold: Int,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if resizeCount(app) > threshold { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return resizeCount(app) > threshold
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
