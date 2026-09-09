import XCTest

@MainActor
final class WindowRelaunchUITests: XCTestCase {
    func testFreshSessionLaunchReplacesAnOrphanedTerminalWindow() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["scene-title-Alpha"].waitForExistence(timeout: 30))
        app.terminate()

        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Beta",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-title-Beta"].waitForExistence(timeout: 30))
    }

    func testPreviewLaunchRemainsReachableAfterTerminalWindowRestoration() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["scene-title-Alpha"].waitForExistence(timeout: 30))
        app.terminate()

        app.launchArguments = ["-uitest-terminal-preview", "-uitest-session-id", "relaunch-regression"]
        app.launch()

        XCTAssertTrue(app.staticTexts["previewState"].waitForExistence(timeout: 10))
    }
}
