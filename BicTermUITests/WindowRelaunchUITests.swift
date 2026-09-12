import XCTest
import UIKit

@MainActor
final class WindowRelaunchUITests: XCTestCase {
    func testNewConnectionFromTerminalPreservesBothSessionsAndSeparateIPadWindows() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "--uitest-reset", "--uitest-seed-keys", "--uitest-sessions",
            "--uitest-pretrust-fixtures", "--uitest-open-session", "Alpha",
            "--uitest-session-command", "printf '__ORIGINAL_WINDOW__\\n'",
        ]
        app.launch()
        let original = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        let marker = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "__ORIGINAL_WINDOW__"),
            object: original
        )
        XCTAssertEqual(XCTWaiter.wait(for: [marker], timeout: 30), .completed)
        capture(app, name: "new-window-original")
        app.buttons["scene-menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["scene-new-session"].waitForExistence(timeout: 5))
        app.buttons["scene-new-session"].tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["list-done"].waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.buttons["connection-Beta"].firstMatch.waitForExistence(timeout: 10))
        let beta = try XCTUnwrap(app.buttons.matching(identifier: "connection-Beta")
            .allElementsBoundByIndex.first(where: \.isHittable))
        beta.swipeLeft()
        let connect = try XCTUnwrap(app.buttons.matching(identifier: "connect-Beta")
            .allElementsBoundByIndex.first(where: \.isHittable))

        connect.tap()

        XCTAssertTrue(app.staticTexts["scene-title-Beta"].waitForExistence(timeout: 30))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let alphaWindow = app.windows.containing(.staticText, identifier: "scene-title-Alpha")
            let betaWindow = app.windows.containing(.staticText, identifier: "scene-title-Beta")
            XCTAssertEqual(alphaWindow.count, 1)
            XCTAssertEqual(betaWindow.count, 1)
            XCTAssertFalse(betaWindow.firstMatch.staticTexts["scene-title-Alpha"].exists)
            XCTAssertTrue(original.label.contains("__ORIGINAL_WINDOW__"))
            XCTAssertTrue(app.staticTexts["scene-status-Alpha"].label.contains("status:active"))
        }
        let active = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "status:active"),
            object: app.staticTexts["scene-status-Beta"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 30), .completed)
        capture(app, name: "new-window-second")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
