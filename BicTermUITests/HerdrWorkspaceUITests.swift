import XCTest

/// T16 herdr workspace UI tests: committed real-codec frames replayed
/// through the DEBUG in-app transport drive the full native chrome —
/// handshake, tab bar, 2x2 pane tree with focus, surface renderer, and the
/// version-gate diagnostic screen. Both canonical simulators.
final class HerdrWorkspaceUITests: XCTestCase {
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
    }

    private func launchApp(mode: String, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-replay", "--uitest-herdr-mode", mode]
        if accessibilitySize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityM",
            ]
        }
        app.launchEnvironment["HERDR_FIXTURE_DIR"] = herdirFixtureDir
        app.launchEnvironment["HERDR_VENDOR_GOLDEN_DIR"] = vendorGoldenDir
        app.launch()
        return app
    }

    func testWorkspaceRendersTwoByTwoPaneTreeFromCommittedFrames() throws {
        let app = launchApp(mode: "workspace")

        let badge = app.descendants(matching: .any)["herdr-status-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "workspace chrome must appear")
        XCTAssertEqual(badge.label, "Online", "the golden welcome must complete the handshake")

        XCTAssertTrue(app.descendants(matching: .any)["herdr-endpoint-label"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["herdr-tab-1"].exists, "the tab bar renders the focused workspace's tab")

        let focused = app.descendants(matching: .any)["herdr-pane-w1:p2"]
        XCTAssertTrue(focused.waitForExistence(timeout: 10), "all four panes of the 2x2 tree render")
        XCTAssertTrue(app.descendants(matching: .any)["herdr-pane-w1:p1"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["herdr-pane-w1:p3"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["herdr-pane-w1:p4"].exists)
        XCTAssertTrue(focused.isSelected, "w1:p2 carries the focused trait from the snapshot")

        XCTAssertTrue(
            focused.label.contains("focused"),
            "pane chrome exposes a VoiceOver label: \(focused.label)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["herdr-disconnect"].isHittable)

        attachScreenshot(app, name: "herdr-workspace-2x2")
    }

    func testVersionGateDiagnosticScreenForWrongGenerationWelcome() throws {
        let app = launchApp(mode: "gen99")

        let diagnostic = app.descendants(matching: .any)["herdr-diagnostic"]
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10), "the gen-99 welcome must open the diagnostic screen")

        let localVersion = app.descendants(matching: .any)["herdr-diagnostic-local-version"]
        XCTAssertTrue(localVersion.exists)
        XCTAssertTrue(localVersion.label.contains("0.9.0"), "local protocol-core version is shown")

        let generation = app.descendants(matching: .any)["herdr-diagnostic-generation"]
        XCTAssertTrue(generation.exists)
        XCTAssertTrue(generation.label.contains("generation 1"), "the endpoint generation this app supports is shown")

        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-diagnostic-remediation"].exists,
            "compatibility failures must link remediation"
        )

        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-pane-w1:p1"].exists,
            "no workspace pane may render behind the version gate"
        )

        attachScreenshot(app, name: "herdr-version-gate-gen99")
    }

    /// Informational (plan T16): the chrome survives a Dynamic Type change —
    /// asserted by relaunching at an accessibility content size.
    func testPaneChromeSurvivesAccessibilityDynamicType() throws {
        let app = launchApp(mode: "workspace", accessibilitySize: true)

        let focused = app.descendants(matching: .any)["herdr-pane-w1:p2"]
        XCTAssertTrue(focused.waitForExistence(timeout: 10), "pane chrome survives the accessibility content size")
        XCTAssertTrue(app.descendants(matching: .any)["herdr-tab-1"].exists)
        XCTAssertTrue(
            focused.label.contains("focused"),
            "accessibility labels remain intact at the larger type size"
        )

        XCTContext.runActivity(named: "informational: dynamic type survival logged") { activity in
            activity.add(XCTAttachment(string: "herdr chrome identifiers intact under UICTContentSizeCategoryAccessibilityM"))
        }

        attachScreenshot(app, name: "herdr-workspace-accessibility-type")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
