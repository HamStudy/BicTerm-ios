import XCTest

@MainActor
final class CoderServersUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchReset(fakeValidation: Bool = false, workspaces: Bool = false, unauthorized: Bool = false) {
        var arguments = ["-uitest-reset-configuration"]
        if fakeValidation {
            arguments.append("--uitest-coder-fake-validation")
        }
        if workspaces {
            arguments.append("--uitest-coder-workspaces")
        }
        if unauthorized {
            arguments.append("--uitest-coder-unauthorized")
        }
        app.launchArguments = arguments
        app.launch()
        openCoderServers()
    }

    private func launchWithWorkspaces() {
        launchReset(fakeValidation: true, workspaces: true)
    }

    private func openCoderServers() {
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-coder-servers"].waitForExistence(timeout: 5))
        app.buttons["settings-coder-servers"].tap()
        XCTAssertTrue(app.navigationBars["Coder Servers"].waitForExistence(timeout: 5))
    }

    private func dismissToConnections() {
        let coderBack = app.navigationBars["Coder Servers"].buttons.element(boundBy: 0)
        XCTAssertTrue(coderBack.waitForExistence(timeout: 5))
        coderBack.tap()
        let settingsBack = app.navigationBars["Settings"].buttons.element(boundBy: 0)
        XCTAssertTrue(settingsBack.waitForExistence(timeout: 5))
        settingsBack.tap()
    }

    private func openNewConnectionEditor() {
        let add = app.buttons["add-connection"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
    }

    private func enterText(_ text: String, in field: XCUIElement) {
        tap(field)
        field.clearText()
        field.typeText(text)
    }

    private func dismissKeyboard() {
        let toolbarDone = app.toolbars.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        for keyLabel in ["return", "done"] where app.keyboards.buttons[keyLabel].exists {
            app.keyboards.buttons[keyLabel].tap()
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func selectCoderProtocol() {
        app.buttons["protocol-picker"].tap()
        let coder = app.buttons["Coder"]
        XCTAssertTrue(coder.waitForExistence(timeout: 5))
        coder.tap()
    }

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        app.buttons["key-selector"].tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
    }

    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 5) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }

    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func waitForAddEditor() {
        XCTAssertTrue(app.navigationBars["Add Coder Server"].waitForExistence(timeout: 5))
    }

    private func waitForEditEditor() {
        XCTAssertTrue(app.navigationBars["Edit Coder Server"].waitForExistence(timeout: 5))
    }

    func testAddCoderServerRejectsHTTPAndRequiresHTTPS() {
        launchReset()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()

        enterText("Local HTTP", in: app.textFields["coder-server-name"])
        enterText("http://127.0.0.1:3000", in: app.textFields["coder-server-url"])

        let urlError = app.staticTexts["coder-server-url-error"]
        XCTAssertTrue(urlError.waitForExistence(timeout: 5))
        XCTAssertTrue(urlError.label.contains("HTTPS"))
        XCTAssertFalse(app.buttons["coder-server-validate-save"].isEnabled)

        app.buttons["coder-server-cancel"].tap()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()

        enterText("HTTPS Only", in: app.textFields["coder-server-name"])
        enterText("coder.example.com", in: app.textFields["coder-server-url"])
        XCTAssertFalse(urlError.exists)
        enterText("ignored", in: app.secureTextFields["coder-server-token"])

        XCTAssertTrue(app.buttons["coder-server-validate-save"].isEnabled)
        app.buttons["coder-server-cancel"].tap()
    }

    func testEmptyStateAndAddServerFlow() {
        launchReset(fakeValidation: true)

        XCTAssertTrue(app.staticTexts["coder-servers-empty"].waitForExistence(timeout: 5))

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()

        enterText("Preview Server", in: app.textFields["coder-server-name"])
        enterText("preview.example.com", in: app.textFields["coder-server-url"])
        enterText("invalid-token", in: app.secureTextFields["coder-server-token"])

        app.buttons["coder-server-validate-save"].tap()

        let error = app.staticTexts["coder-server-validation-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))

        app.buttons["coder-server-cancel"].tap()
        XCTAssertFalse(app.buttons["coder-server-Preview-Server"].exists)
    }

    func testTokenIsMaskedAndNotInAccessibilityTree() {
        launchReset()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()

        let secret = "super-secreT-1234"
        enterText(secret, in: app.secureTextFields["coder-server-token"])

        let description = app.debugDescription
        XCTAssertFalse(description.contains(secret), "secret token must not appear in accessibility tree")
        XCTAssertFalse(description.contains("super-secreT"), "partial token must not appear in accessibility tree")

        app.buttons["coder-server-cancel"].tap()
    }

    func testCancelLeavesListEmpty() {
        launchReset()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()
        enterText("Abandoned", in: app.textFields["coder-server-name"])
        enterText("abandoned.example.com", in: app.textFields["coder-server-url"])
        enterText("abandoned-token", in: app.secureTextFields["coder-server-token"])

        app.buttons["coder-server-cancel"].tap()
        XCTAssertFalse(app.buttons["coder-server-Abandoned"].exists)
    }

    func testSuccessfulSaveAndMaskingOnEdit() {
        launchReset(fakeValidation: true)

        XCTAssertTrue(app.staticTexts["coder-servers-empty"].waitForExistence(timeout: 5))

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()
        enterText("Preview Server", in: app.textFields["coder-server-name"])
        enterText("preview.example.com", in: app.textFields["coder-server-url"])
        enterText("fixture-token", in: app.secureTextFields["coder-server-token"])

        app.buttons["coder-server-validate-save"].tap()

        let row = app.buttons["coder-server-Preview-Server"]
        if !row.waitForExistence(timeout: 10) {
            let errorText = app.staticTexts["coder-server-validation-error"]
            if errorText.exists {
                XCTFail("Save failed with error: \(errorText.label)")
            } else {
                print(app.debugDescription)
                XCTFail("Saved row did not appear after 10 seconds")
            }
            return
        }
        XCTAssertTrue(row.label.contains("Configured"), "Saved row should show configured status: \(row.label)")
        XCTAssertTrue(app.navigationBars["Coder Servers"].exists)
        XCTAssertFalse(app.navigationBars.matching(identifier: "Add Coder Server").firstMatch.exists)

        tap(row)
        waitForEditEditor()

        let description = app.debugDescription
        XCTAssertFalse(description.contains("fixture-token"), "saved token must not appear in edit sheet")
        XCTAssertTrue(app.staticTexts["coder-token-hint"].exists, "edit sheet should show masked-token hint")

        app.buttons["coder-server-cancel"].tap()
    }

    // MARK: T19 — Coder connection editor integration

    func testCoderConnectionEditorListsServersAndWorkspaces() {
        app.launchArguments = [
            "-uitest-reset-configuration",
            "--uitest-coder-fake-validation",
            "--uitest-coder-workspaces",
            "--uitest-reset-keys",
            "--uitest-seed-keys",
        ]
        app.launch()
        openCoderServers()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()
        enterText("Fixture Server", in: app.textFields["coder-server-name"])
        enterText("https://coder.example.com", in: app.textFields["coder-server-url"])
        enterText("any-token", in: app.secureTextFields["coder-server-token"])
        app.buttons["coder-server-validate-save"].tap()

        let serverRow = app.buttons["coder-server-Fixture-Server"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 10))
        dismissToConnections()

        openNewConnectionEditor()

        enterText("Coder Connection", in: app.textFields["field-name"])
        selectCoderProtocol()
        enterText("coder.example.com", in: app.textFields["field-host"])
        enterText("user", in: app.textFields["field-username"])

        let serverPicker = app.buttons["coder-server-picker"]
        scrollToHittable(serverPicker)
        serverPicker.tap()
        let serverChoice = app.buttons["Fixture Server"]
        XCTAssertTrue(serverChoice.waitForExistence(timeout: 5))
        serverChoice.tap()

        let runningWorkspace = app.buttons["coder-workspace-Running-Dev"]
        XCTAssertTrue(runningWorkspace.waitForExistence(timeout: 10))
        XCTAssertTrue(runningWorkspace.isEnabled)
        XCTAssertTrue(app.staticTexts["Running"].exists)

        let stoppedWorkspace = app.buttons["coder-workspace-Stopped-Old"]
        XCTAssertTrue(stoppedWorkspace.exists)
        XCTAssertFalse(stoppedWorkspace.isEnabled, "stopped workspace must not be selectable")
        XCTAssertTrue(app.staticTexts["Stopped"].exists)

        runningWorkspace.tap()
        selectAuthenticationKey("Fixture Ed25519")

        let connect = app.buttons["connect-button"]
        scrollToHittable(connect)
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        let alert = app.alerts["Coder tunnel not yet available"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Coder tunnel not yet available"].exists)
        XCTAssertFalse(alert.staticTexts["Coder tunnel support is not yet available."].exists)
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.otherElements["terminalView"].exists)
        XCTAssertFalse(app.otherElements["terminalPlaceholder"].exists)
    }

    func testCoderReauthenticateNavigatesToServerEditor() {
        app.launchArguments = [
            "-uitest-reset-configuration",
            "--uitest-coder-fake-validation",
            "--uitest-coder-workspaces",
        ]
        app.launch()
        openCoderServers()

        app.buttons["add-coder-server"].tap()
        waitForAddEditor()
        enterText("Expired Server", in: app.textFields["coder-server-name"])
        enterText("https://coder.example.com", in: app.textFields["coder-server-url"])
        enterText("fixture-token", in: app.secureTextFields["coder-server-token"])
        app.buttons["coder-server-validate-save"].tap()

        let serverRow = app.buttons["coder-server-Expired-Server"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 10))
        dismissToConnections()

        app.terminate()
        app.launchArguments = [
            "--uitest-coder-fake-validation",
            "--uitest-coder-unauthorized",
        ]
        app.launch()

        openNewConnectionEditor()
        enterText("Expired Connection", in: app.textFields["field-name"])
        selectCoderProtocol()

        let serverPicker = app.buttons["coder-server-picker"]
        scrollToHittable(serverPicker)
        serverPicker.tap()
        let serverChoice = app.buttons["Expired Server"]
        XCTAssertTrue(serverChoice.waitForExistence(timeout: 5))
        serverChoice.tap()

        let reauth = app.buttons["coder-reauthenticate"]
        scrollToHittable(reauth)
        XCTAssertTrue(reauth.waitForExistence(timeout: 10))
        reauth.tap()

        let serverNameField = app.textFields["coder-server-name"]
        XCTAssertTrue(serverNameField.waitForExistence(timeout: 10))
        XCTAssertEqual(serverNameField.value as? String, "Expired Server")
    }
}

private extension XCUIElement {
    func clearText() {
        guard let current = value as? String, !current.isEmpty else { return }
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 20)
        typeText(deletes)
    }
}
