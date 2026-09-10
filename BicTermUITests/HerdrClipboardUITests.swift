import XCTest

/// T18 herdr clipboard UI tests: the DEBUG replay (mode `clipboard`) drives
/// the input fence plus one OSC 52 server clipboard chunk, so the suite
/// exercises both clipboard directions against the live workspace chrome.
/// The test process seeds the simulator-wide pasteboard BEFORE launch; every
/// app-side read must be gesture-mediated (UIPasteControl tap or cmd+v), and
/// the DEBUG stats line (`herdr-pasteboard-stats`) proves zero automatic
/// reads. Echoes carry byte counts only — redaction assertions pin that
/// clipboard content never reaches the UI surface. Both canonical
/// simulators.
final class HerdrClipboardUITests: XCTestCase {
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

    override func tearDownWithError() throws {
        UIPasteboard.general.string = ""
    }

    private func launchApp(hwkeys: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-replay", "--uitest-herdr-mode", "clipboard"]
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
        XCTAssertTrue(
            ready.waitForExistence(timeout: 15),
            "the fence plus the clipboard chunk must fully apply"
        )
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

    private func statsText(_ app: XCUIApplication) -> String {
        app.staticTexts["herdr-pasteboard-stats"].label
    }

    /// The synthetic cmd+v token reads the pasteboard from app code, which
    /// UIKit cannot attribute to a gesture: the system paste permission
    /// prompt is SpringBoard-hosted and blocks the read until answered.
    /// Grant it once so the send can proceed. UIPasteControl taps are
    /// system-consented and never raise it, so those paths assert strictly.
    private func allowSystemPastePromptIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Paste", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 10) {
                button.tap()
                return
            }
        }
    }

    // MARK: - Local paste gestures (doc §8.2)

    func testPasteGestureReadsOnceAndSendsByteExact() throws {
        UIPasteboard.general.string = "ui-paste-sentinel"
        let app = launchApp()
        waitForReplayReady(app)

        XCTAssertEqual(
            statsText(app), "pasteboard r:0 w:0",
            "no automatic pasteboard read before the gesture"
        )

        app.descendants(matching: .any)["herdr-paste-control"].tap()
        XCTAssertTrue(
            waitForEcho(app, contains: "paste(17B→w1:p2)"),
            "the seeded text sends to the focused pane (echo: \(echoText(app)))"
        )
        XCTAssertEqual(
            statsText(app), "pasteboard r:1 w:0",
            "exactly one content read per gesture; hasStrings is metadata-only"
        )
        XCTAssertFalse(
            echoText(app).contains("ui-paste-sentinel"),
            "echoes carry byte counts, never content"
        )
        attachScreenshot(app, name: "herdr-clipboard-paste-gesture")
    }

    func testCommandVKeyboardChordPastes() throws {
        UIPasteboard.general.string = "hw-chord"
        let app = launchApp(hwkeys: "cmd+v")

        // The injector fires on the ready signal — drain the prompt first
        // (SpringBoard hosts it) so the blocked main thread cannot wedge the
        // very queries that confirm the send.
        allowSystemPastePromptIfShown()
        waitForReplayReady(app)

        XCTAssertTrue(
            waitForEcho(app, contains: "paste(8B→w1:p2)"),
            "the hardware chord resolves to the paste gesture (echo: \(echoText(app)))"
        )
        XCTAssertFalse(echoText(app).contains("hw-chord"))
    }

    func testLargePasteConfirmsDestinationPane() throws {
        UIPasteboard.general.string = String(repeating: "y", count: 100_000)
        let app = launchApp()
        waitForReplayReady(app)

        app.descendants(matching: .any)["herdr-paste-control"].tap()
        let alert = app.alerts["Large Paste"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: 5),
            "a paste at the threshold confirms first"
        )
        XCTAssertTrue(
            alert.staticTexts
                .element(matching: NSPredicate(format: "label CONTAINS %@", "100000 bytes"))
                .exists,
            "the confirmation states the payload size"
        )
        XCTAssertTrue(
            alert.staticTexts
                .element(matching: NSPredicate(format: "label CONTAINS %@", "w1:p2"))
                .exists,
            "the confirmation names the destination pane captured at gesture time"
        )

        alert.buttons["Paste"].tap()
        XCTAssertTrue(
            waitForEcho(app, contains: "paste(100000B→w1:p2)"),
            "approval sends the exact approved text (echo: \(echoText(app)))"
        )
    }

    // MARK: - Remote clipboard (doc §8.3)

    func testRemoteClipboardCopyGestureWritesAndRepastes() throws {
        let app = launchApp()
        waitForReplayReady(app)

        let banner = app.descendants(matching: .any)["herdr-remote-clipboard-banner"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 5),
            "the OSC 52 chunk surfaces as a banner, never a silent write (echo: \(echoText(app)))"
        )
        XCTAssertEqual(
            statsText(app), "pasteboard r:0 w:0",
            "arrival never touches the system pasteboard by default"
        )

        app.descendants(matching: .any)["herdr-copy-remote"].tap()
        XCTAssertTrue(
            waitForEcho(app, contains: "copyRemote(27B)"),
            "the explicit copy records a byte-count echo (echo: \(echoText(app)))"
        )
        XCTAssertEqual(statsText(app), "pasteboard r:0 w:1", "one write per copy gesture")

        // End to end: the pasteboard now holds the remote text, so the next
        // paste gesture sends the same 27 bytes back to the focused pane.
        app.descendants(matching: .any)["herdr-paste-control"].tap()
        XCTAssertTrue(
            waitForEcho(app, contains: "paste(27B→w1:p2)"),
            "the copied remote clipboard is what the next gesture pastes (echo: \(echoText(app)))"
        )
        XCTAssertFalse(echoText(app).contains("hello remote"))
        attachScreenshot(app, name: "herdr-clipboard-remote-copy")
    }

    func testAutoCopyOptInWritesOnArrival() throws {
        let app = launchApp()
        waitForReplayReady(app)

        let banner = app.descendants(matching: .any)["herdr-remote-clipboard-banner"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 5),
            "the OSC 52 chunk surfaces as a banner (echo: \(echoText(app)))"
        )
        app.descendants(matching: .any)["herdr-autocopy-remote"].tap()
        XCTAssertTrue(
            waitForEcho(app, contains: "autoCopyRemote(27B)"),
            "the per-host opt-in applies the pending clipboard immediately (echo: \(echoText(app)))"
        )
        XCTAssertEqual(statsText(app), "pasteboard r:0 w:1")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
