import XCTest

/// Drives the password-auth editor flows: the segmented Key|Password pickers,
/// the never-prefilled SecureField, the "Saved in Keychain" badge, and
/// persistence across relaunch. All runs launch with `--uitest-pwd-server`
/// (DEBUG-only in-app accept-password NIOSSH server on loopback) so the seam
/// itself stays exercised even though these tests stop at the editor layer —
/// the end-to-end password handshake proof lives in BicTermCoreTests.
@MainActor
final class PasswordAuthUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: Destination password — create, persist, reopen with badge

    func testPasswordDestinationPersistsAndNeverPrefills() {
        launchApp(arguments: ["--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Password Auth")
        typeInto(app.textFields["field-host"], "127.0.0.1")
        typeInto(app.textFields["field-port"], "18090", clearing: "22")
        typeInto(app.textFields["field-username"], "uitest")

        selectSegment("Password", in: "auth-method-picker")
        let secureField = app.secureTextFields["password-field"]
        XCTAssertTrue(secureField.waitForExistence(timeout: 5), "password mode must swap the key picker for a SecureField")
        XCTAssertFalse(app.buttons["key-selector"].exists, "password mode must not offer key selection")
        XCTAssertTrue(app.staticTexts["password-field-error"].exists, "empty password must keep save gated")

        typeIntoSecure(secureField, "bicterm-uitest-fixture-password")
        XCTAssertFalse(app.staticTexts["password-field-error"].exists)
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        dismissSavePasswordPromptIfPresent()

        let row = app.buttons["connection-Password-Auth"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        app.terminate()
        launchApp(arguments: ["--uitest-pwd-server"])
        XCTAssertTrue(app.buttons["connection-Password-Auth"].waitForExistence(timeout: 10), "connection must survive relaunch")

        openEditorForConnection(named: "Password-Auth")

        let reopenedSecure = app.secureTextFields["password-field"]
        scrollToHittable(reopenedSecure)
        XCTAssertTrue(reopenedSecure.exists)
        XCTAssertTrue(app.staticTexts["password-saved-badge"].exists, "saved password shows a badge, never prefilled text")
        XCTAssertTrue(app.buttons["key-selector"].exists == false)
        let value = reopenedSecure.value as? String
        XCTAssertTrue(value == nil || value == "", "SecureField must never be pre-filled from the store; got \(value ?? "<nil>")")
        waitForEnabled(app.buttons["save-editor"])

        app.buttons["cancel-editor"].tap()
    }

    // MARK: Hop password — picker sheet, badge, persisted hop

    func testPasswordHopPersistsAndReopensWithBadge() {
        launchApp(arguments: ["--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Password Hop")
        typeInto(app.textFields["field-host"], "10.7.7.7")
        typeInto(app.textFields["field-username"], "dest-user")
        selectAuthenticationKey("Fixture Ed25519")

        addPasswordHop(host: "127.0.0.1", port: "12222", username: "hop1user", password: "hop-secret-9")

        let credential = app.staticTexts["hop-0-credential"]
        scrollToHittable(credential, swipingUp: false)
        XCTAssertEqual(credential.label, "hop1user · Password")

        app.buttons["save-editor"].tap()
        dismissSavePasswordPromptIfPresent()
        XCTAssertTrue(app.buttons["connection-Password-Hop"].waitForExistence(timeout: 10))

        app.terminate()
        launchApp(arguments: ["--uitest-pwd-server"])
        XCTAssertTrue(app.buttons["connection-Password-Hop"].waitForExistence(timeout: 10))

        openEditorForConnection(named: "Password-Hop")
        let editHop = app.buttons["edit-hop-0"]
        scrollToHittable(editHop)
        editHop.tap()

        let hopSecure = app.secureTextFields["hop-password-field"]
        XCTAssertTrue(hopSecure.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["hop-password-saved-badge"].exists)
        XCTAssertFalse(app.buttons["hop-key-selector"].exists)
        let hopValue = hopSecure.value as? String
        XCTAssertTrue(hopValue == nil || hopValue == "", "hop password SecureField must never pre-fill; got \(hopValue ?? "<nil>")")
        waitForEnabled(app.buttons["save-hop"])

        app.buttons["cancel-hop"].tap()
        app.buttons["cancel-editor"].tap()
    }

    // MARK: Duplicate — pre-filled add flow keeps the saved password

    func testDuplicateKeepsSavedPasswordWithoutRetyping() {
        launchApp(arguments: ["--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Password Auth")
        typeInto(app.textFields["field-host"], "127.0.0.1")
        typeInto(app.textFields["field-port"], "18090", clearing: "22")
        typeInto(app.textFields["field-username"], "uitest")
        selectSegment("Password", in: "auth-method-picker")
        typeIntoSecure(app.secureTextFields["password-field"], "bicterm-uitest-fixture-password")
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        dismissSavePasswordPromptIfPresent()
        XCTAssertTrue(app.buttons["connection-Password-Auth"].waitForExistence(timeout: 10))

        // The duplicate shares the source's Keychain tag: the editor opens
        // with the saved-password badge and Save stays enabled with no
        // retype and no rewrite of the entry.
        swipeRow(named: "Password-Auth")
        let duplicate = app.buttons["duplicate-Password-Auth"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()

        XCTAssertTrue(app.navigationBars["New Connection"].waitForExistence(timeout: 10),
                      "duplicate must open as an add flow")
        XCTAssertEqual(app.textFields["field-name"].value as? String, "Password Auth (copy)")
        let secure = app.secureTextFields["password-field"]
        scrollToHittable(secure)
        XCTAssertTrue(secure.exists)
        XCTAssertTrue(app.staticTexts["password-saved-badge"].exists,
                      "duplicate must inherit the saved-password state, never require retyping")
        let value = secure.value as? String
        XCTAssertTrue(value == nil || value == "", "SecureField must stay empty; got \(value ?? "<nil>")")
        waitForEnabled(app.buttons["save-editor"])

        app.buttons["save-editor"].tap()
        dismissSavePasswordPromptIfPresent()
        XCTAssertTrue(app.buttons["connection-Password-Auth-(copy)"].waitForExistence(timeout: 10))

        // Deleting the source must not orphan the shared entry: the copy
        // still opens with the saved-password badge.
        swipeRow(named: "Password-Auth")
        let delete = app.buttons["delete-Password-Auth"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let originalGone = NSPredicate(format: "exists == false")
        expectation(for: originalGone, evaluatedWith: app.buttons["connection-Password-Auth"])
        waitForExpectations(timeout: 10)

        openEditorForConnection(named: "Password-Auth-(copy)")
        let reopenedSecure = app.secureTextFields["password-field"]
        scrollToHittable(reopenedSecure)
        XCTAssertTrue(reopenedSecure.exists)
        XCTAssertTrue(app.staticTexts["password-saved-badge"].exists,
                      "deleting the source must leave the copy's shared password entry intact")
        app.buttons["cancel-editor"].tap()
    }

    // MARK: Picker toggles

    func testSwitchingAuthMethodTogglesCredentialFields() {
        launchApp(arguments: ["--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        XCTAssertTrue(app.buttons["key-selector"].exists, "new connections start in key mode")
        XCTAssertFalse(app.secureTextFields["password-field"].exists)

        selectSegment("Password", in: "auth-method-picker")
        XCTAssertTrue(app.secureTextFields["password-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["key-selector"].exists)

        selectSegment("Key", in: "auth-method-picker")
        let keySelector = app.buttons["key-selector"]
        scrollToHittable(keySelector, swipingUp: false)
        XCTAssertTrue(keySelector.exists)
        XCTAssertFalse(app.secureTextFields["password-field"].exists)

        app.buttons["cancel-editor"].tap()
    }

    // MARK: Helpers

    private func launchApp(arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    private func openEditorForNewConnection() {
        let add = app.buttons["add-connection"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
    }

    private func openEditorForConnection(named identifier: String) {
        swipeRow(named: identifier)
        let edit = app.buttons["edit-\(identifier)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.buttons["cancel-editor"].waitForExistence(timeout: 10))
    }

    private func selectSegment(_ title: String, in pickerIdentifier: String) {
        dismissKeyboard()
        let picker = app.segmentedControls[pickerIdentifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "auth method segmented picker must exist")
        let segment = picker.buttons[title]
        XCTAssertTrue(segment.exists, "segment \(title) must exist")
        segment.tap()
    }

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        let selector = app.buttons["key-selector"]
        scrollToHittable(selector)
        selector.tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
    }

    private func addPasswordHop(host: String, port: String, username: String, password: String) {
        let addHopButton = app.buttons["add-hop"]
        scrollToHittable(addHopButton)
        addHopButton.tap()

        let hostField = app.textFields["hop-field-host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        typeInto(hostField, host)
        typeInto(app.textFields["hop-field-port"], port, clearing: "22")
        typeInto(app.textFields["hop-field-username"], username)

        selectSegment("Password", in: "hop-auth-method-picker")
        let secure = app.secureTextFields["hop-password-field"]
        XCTAssertTrue(secure.waitForExistence(timeout: 5))
        typeIntoSecure(secure, password)

        let save = app.buttons["save-hop"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        waitForEnabled(save)
        save.tap()
        let sheetDismissed = NSPredicate(format: "exists == false")
        expectation(for: sheetDismissed, evaluatedWith: app.buttons["save-hop"])
        expectation(for: sheetDismissed, evaluatedWith: hostField)
        waitForExpectations(timeout: 10)
        dismissSavePasswordPromptIfPresent()
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func typeInto(_ field: XCUIElement, _ text: String, clearing existing: String? = nil) {
        scrollToHittable(field, swipingUp: false)
        field.tap()
        awaitKeyboardFocus(on: field)
        if existing != nil {
            clearField(field)
        }
        app.typeText(text)
        // Value-equality is the typing receipt: it catches silent prepending
        // (failed clear) and dropped input instead of letting a later
        // enablement check time out with no diagnosis.
        XCTAssertEqual(field.value as? String, text, "input must land exactly")
        dismissKeyboard()
    }

    private func typeIntoSecure(_ field: XCUIElement, _ text: String) {
        scrollToHittable(field, swipingUp: false)
        // Tap toward the trailing edge: on regular-width sheets SwiftUI can
        // report the whole row as the field's frame, and a center tap then
        // lands between the label and the text box, never focusing the
        // editor. 75% width is inside the text box in both AX shapes.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        awaitKeyboardFocus(on: field)
        app.typeText(text)
        let bullets = field.value as? String
        XCTAssertEqual(bullets?.count, text.count, "secure input must land exactly")
        dismissKeyboard()
    }

    private func awaitKeyboardFocus(on field: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: timeout)
    }

    /// Binding updates land one render tick late on relaxed-timing hosts
    /// (observed: iPad simulator with hardware keyboard); poll instead of
    /// reading `isEnabled` synchronously.
    private func waitForEnabled(_ button: XCUIElement, timeout: TimeInterval = 8) {
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: timeout)
    }

    private func clearField(_ field: XCUIElement) {
        // Double-tap selects the whole word ("22"-style defaults are a single
        // token), so the following typeText REPLACES it. The long-press
        // callout never surfaces inside iPad form sheets, and control-key
        // backspaces are dropped by the number-pad keyboard there — both
        // observed as silent prepends ("1809022"). The typeInto receipt
        // remains the final arbiter.
        field.doubleTap()
    }

    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let toolbarDone = app.toolbars.buttons["Done"]
        let plainDone = app.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        if plainDone.exists {
            plainDone.tap()
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

    /// iOS may offer to save a SecureField value after the editor sheet
    /// dismisses; decline so the prompt never overlaps later assertions.
    private func dismissSavePasswordPromptIfPresent() {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) {
            notNow.tap()
        }
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        swipingUp: Bool = true,
        maxSwipes: Int = 8
    ) {
        var attempts = 0
        while !isFullyVisibleInWindow(element) && attempts < maxSwipes {
            if swipingUp {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            attempts += 1
        }
    }

    private func isFullyVisibleInWindow(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        let inset: CGFloat = 8
        guard frame.minX >= window.minX + inset,
              frame.maxX <= window.maxX - inset,
              frame.minY >= window.minY + inset,
              frame.maxY <= window.maxY - inset else { return false }
        let navBars = app.navigationBars
        for index in 0..<navBars.count {
            let bar = navBars.element(boundBy: index).frame
            if !bar.isEmpty, frame.minY < bar.maxY + 4 { return false }
        }
        return true
    }

    private func swipeRow(named identifier: String) {
        let row = app.buttons["connection-\(identifier)"]
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            row.swipeLeft()
        }
    }
}
