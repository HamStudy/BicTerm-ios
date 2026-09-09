import XCTest

@MainActor
final class CoderEditorFocusUITests: XCTestCase {
    private func addServer() -> XCUIApplication {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "-uitest-reset-configuration",
            "--uitest-coder-fake-validation",
            "--uitest-coder-workspaces",
            "--uitest-force-connection-list",
        ]
        app.launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-coder-servers"].tap()
        app.buttons["add-coder-server"].tap()
        let serverName = app.textFields["coder-server-name"]
        XCTAssertTrue(serverName.waitForExistence(timeout: 5))
        serverName.tap()
        serverName.typeText("Focus Server")
        let url = app.textFields["coder-server-url"]
        url.tap()
        url.typeText("https://coder.example.com")
        let token = app.secureTextFields["coder-server-token"]
        token.tap()
        token.typeText("fixture-token")
        app.buttons["coder-server-validate-save"].tap()
        XCTAssertTrue(app.buttons["coder-server-Focus-Server"].waitForExistence(timeout: 10))
        return app
    }

    func testServerRowCenterOpensSavedServerForEditing() {
        let app = addServer()

        app.buttons["coder-server-Focus-Server"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.navigationBars["Edit Coder Server"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["coder-server-name"].value as? String, "Focus Server")
    }

    func testServerSelectionRemainsReachableAfterTypingNameAndChangingProtocol() {
        let app = addServer()
        app.navigationBars["Coder Servers"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.buttons["add-connection"].tap()
        let name = app.textFields["field-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Focus Connection")

        app.buttons["protocol-picker"].tap()
        app.buttons["Coder"].tap()
        let picker = app.buttons["coder-server-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        let choice = app.buttons["Focus Server"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(app.buttons["coder-workspace-Running-Dev"].waitForExistence(timeout: 10))
    }
}
