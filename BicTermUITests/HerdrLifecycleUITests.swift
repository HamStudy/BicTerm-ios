import XCTest

/// T19 herdr lifecycle UI tests: detach/re-attach continuity over the
/// DEBUG replay (the committed-frame stand-in for a persistent server: the
/// re-attach script's revision-2 snapshot is the authoritative "output
/// continued" state), the doc §10 background/foreground round trip driven
/// by a REAL scene backgrounding (activating Settings backgrounds the app;
/// activating it back foregrounds the same scene), and the doc §11
/// probe-missing diagnostic screen with zero install commands on it.
final class HerdrLifecycleUITests: XCTestCase {
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
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchApp(mode: String, hwkeys: String? = nil) -> XCUIApplication {
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

    private func waitForOnline(_ app: XCUIApplication, timeout: TimeInterval = 15) {
        let badge = app.descendants(matching: .any)["herdr-status-badge"]
        let online = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Online"),
            object: badge
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [online], timeout: timeout), .completed,
            "the endpoint must reach Online (badge: \(badge.label))"
        )
    }

    private func lifecycleEcho(_ app: XCUIApplication) -> String {
        app.staticTexts["herdr-lifecycle-echo"].label
    }

    @discardableResult
    private func waitForLifecycleEcho(
        _ app: XCUIApplication,
        contains needle: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        let echo = app.staticTexts["herdr-lifecycle-echo"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", needle),
            object: echo
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Detach / re-attach continuity

    func testDetachAndReattachPreservesRemoteWorkspaceStateWithoutInputReplay() throws {
        let app = launchApp(mode: "lifecycle", hwkeys: "text:ab")
        waitForOnline(app)

        // Spec hard rule: pre-detach input exists (typed through the real
        // input lane), and after re-attach it must NOT have been replayed.
        let inputEcho = app.staticTexts["herdr-input-echo"]
        for needle in ["text(\"a\"→w1:p2)", "text(\"b\"→w1:p2)"] {
            let typed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", needle),
                object: inputEcho
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [typed], timeout: 15), .completed,
                "pre-detach input commits before the detach (echo: \(inputEcho.label))"
            )
        }

        let detach = app.descendants(matching: .any)["herdr-detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 5), "an online workspace offers Detach")
        detach.tap()

        let diagnostic = app.descendants(matching: .any)["herdr-diagnostic"]
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10), "detaching shows the detached state screen")
        let title = app.descendants(matching: .any)["herdr-diagnostic-title"]
        XCTAssertEqual(title.label, "Detached", "user detach is its own taxonomy state")
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-reattach"].exists,
            "the detached state offers an explicit re-attach"
        )
        XCTAssertTrue(waitForLifecycleEcho(app, contains: "detach:user"), "the detach is recorded")

        app.descendants(matching: .any)["herdr-reattach"].tap()
        waitForOnline(app)
        XCTAssertTrue(
            waitForLifecycleEcho(app, contains: "online:replay-lifecycle:gen:2"),
            "re-attach completes a fresh generation (echo: \(lifecycleEcho(app)))"
        )

        // Authoritative continued state: the revision-2 snapshot moves the
        // input target to w1:p3 — the server's current focus, not ours.
        let refocused = app.descendants(matching: .any)["herdr-pane-w1:p3"]
        XCTAssertTrue(refocused.waitForExistence(timeout: 10))
        let targetted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "input target"),
            object: refocused
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [targetted], timeout: 10), .completed,
            "the re-attached authoritative snapshot owns the input target (label: \(refocused.label))"
        )

        // Never replay speculative input: each pre-detach commit appears
        // exactly once in the echo after the round trip.
        let finalEcho = inputEcho.label
        for needle in ["text(\"a\"→w1:p2)", "text(\"b\"→w1:p2)"] {
            XCTAssertEqual(
                finalEcho.components(separatedBy: needle).count - 1, 1,
                "\(needle) must appear exactly once — no post-reattach replay (echo: \(finalEcho))"
            )
        }

        attachScreenshot(app, name: "herdr-lifecycle-reattach")
    }

    // MARK: - Background / foreground policy (doc §10)

    func testBackgroundClosesTheChannelAndForegroundReconnectsCleanly() throws {
        let app = launchApp(mode: "lifecycle")
        waitForOnline(app)

        // REAL scene backgrounding: activating Settings backgrounds the
        // herdr scene; the finite detach task must close the channel inside
        // the granted window (no background mode beyond it). Settings'
        // activation can lag or drop on the simulator — poll for the
        // backgrounding and re-activate once before giving up.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        var backgrounded = waitForNotForeground(app, timeout: 10)
        if !backgrounded {
            settings.activate()
            backgrounded = waitForNotForeground(app, timeout: 10)
        }
        XCTAssertTrue(backgrounded, "BicTerm must be backgrounded by Settings activation")

        app.activate()
        waitForOnline(app, timeout: 25)
        XCTAssertTrue(
            waitForLifecycleEcho(app, contains: "detach:background"),
            "the background policy's detach is recorded (echo: \(lifecycleEcho(app)))"
        )
        XCTAssertTrue(
            waitForLifecycleEcho(app, contains: "online:replay-lifecycle:gen:2"),
            "foreground reconnects with a fresh generation and authoritative state (echo: \(lifecycleEcho(app)))"
        )

        // Continuity: the workspace is usable again — the revision-2
        // snapshot arrived (w1:p3 is the server's focused pane).
        let refocused = app.descendants(matching: .any)["herdr-pane-w1:p3"]
        XCTAssertTrue(refocused.waitForExistence(timeout: 10), "the reconnected workspace renders panes")

        attachScreenshot(app, name: "herdr-lifecycle-background-foreground")
    }

    // MARK: - Probe-missing diagnostic screen (doc §11)

    func testHostWithoutHerdrShowsProbeDiagnosticScreenWithZeroInstallCommands() throws {
        let app = launchApp(mode: "probe-missing")

        let screen = app.descendants(matching: .any)["herdr-probe-diagnostic"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "the probe failure must open the diagnostic screen")

        let title = app.descendants(matching: .any)["herdr-probe-title"]
        XCTAssertEqual(title.label, "No Herdr found on the host")

        XCTAssertTrue(app.descendants(matching: .any)["herdr-probe-host"].label.contains("fixture-no-herdr"))
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-probe-platform"].label.contains("linux aarch64"),
            "the detected platform is reported"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-probe-path"].label.contains("not found"),
            "no path was found"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-probe-generation"].label.contains("generation 1"),
            "the required endpoint generation is reported"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-probe-remediation"].exists,
            "the official documentation link is offered"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-probe-boundary-note"].exists,
            "the management boundary is stated"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-pane-w1:p1"].exists,
            "no workspace pane may render behind the probe gate"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-reattach"].exists,
            "no re-attach: no bridge channel exists to re-attach to"
        )

        // Zero install commands ON the screen: no label anywhere carries a
        // package-manager or elevation command (belt-and-braces beside the
        // source-level grep test in HerdrInstallBoundaryTests).
        let forbidden = try NSRegularExpression(pattern: #"\bapt(?:-get)?\s+install\b|\bbrew\s+(?:un)?install\b|\bpip3?\s+install\b|\bnpm\s+(?:un)?install\b|\byum\s+install\b|\bsudo\b"#)
        for element in app.descendants(matching: .any).allElementsBoundByIndex {
            let label = element.label
            guard !label.isEmpty else { continue }
            XCTAssertEqual(
                forbidden.numberOfMatches(in: label, range: NSRange(label.startIndex..., in: label)), 0,
                "install-command text surfaced on the probe screen: \(label)"
            )
        }

        attachScreenshot(app, name: "herdr-probe-missing")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Settings activation only eventually takes the foreground; the state
    /// passes through transitional values, so poll for "not foreground".
    private func waitForNotForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.state != .runningForeground
    }
}
