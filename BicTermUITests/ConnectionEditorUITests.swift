import XCTest

@MainActor
final class ConnectionEditorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Scenario 1 — create + persist a 2-hop jump-chain connection

    func testCreateAndPersistTwoHopChainConnection() {
        launchApp(reset: true)

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Chain Two Hop")
        typeInto(app.textFields["field-host"], "10.0.0.9")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        addHop(host: "127.0.0.1", port: "12222", username: "hop1user", key: "Fixture Ed25519")
        addHop(host: "127.0.0.1", port: "12223", username: "hop2user", key: "Fixture Ed25519 Passphrase")

        XCTAssertTrue(app.staticTexts["hop-0-host"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hop-0-host"].label, "127.0.0.1:12222")
        XCTAssertEqual(app.staticTexts["hop-1-host"].label, "127.0.0.1:12223")

        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Chain-Two-Hop"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 hops"].exists)
        XCTAssertTrue(app.staticTexts["ssh"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "connection-list-after-save"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(row.waitForExistence(timeout: 10), "connection must survive relaunch")
        XCTAssertTrue(app.staticTexts["2 hops"].exists)

        row.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["field-name"].value as? String, "Chain Two Hop")
        XCTAssertEqual(app.textFields["field-host"].value as? String, "10.0.0.9")
        XCTAssertEqual(app.textFields["field-username"].value as? String, "alice")
        XCTAssertEqual(app.staticTexts["hop-0-host"].label, "127.0.0.1:12222")
        XCTAssertEqual(app.staticTexts["hop-1-host"].label, "127.0.0.1:12223")
        XCTAssertTrue(app.staticTexts["Fixture Ed25519"].waitForExistence(timeout: 5),
                      "editor must reopen with the same key label")

        app.buttons["cancel-editor"].tap()
    }

    // MARK: Scenario 2 — chain validation blocks bad input

    func testChainValidationBlocksSixthHopAndCycle() {
        launchApp(reset: true)

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Hops Galore")
        typeInto(app.textFields["field-host"], "10.1.2.3")
        typeInto(app.textFields["field-username"], "bob")
        selectAuthenticationKey("Fixture Ed25519")

        for index in 1...5 {
            addHop(host: "hop\(index).example.com", port: nil, username: "u\(index)", key: "Fixture Ed25519")
        }

        app.buttons["add-hop"].tap()
        XCTAssertTrue(app.staticTexts["hop-limit-message"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hop-limit-message"].label, "Maximum 5 hops")
        XCTAssertFalse(app.textFields["hop-field-host"].exists, "6th hop sheet must not open")

        typeInto(app.textFields["field-host"], "hop1.example.com", clearing: "10.1.2.3")
        XCTAssertTrue(app.staticTexts["cycle-warning"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-editor"].isEnabled, "save must be disabled for a cyclic chain")

        typeInto(app.textFields["field-host"], "10.1.2.3", clearing: "hop1.example.com")
        XCTAssertFalse(app.staticTexts["cycle-warning"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-editor"].isEnabled)

        app.buttons["cancel-editor"].tap()
    }

    // MARK: Scenario 3 — key picker lists fixture keys with SHA256 fingerprints

    func testKeyPickerListsFixtureKeysWithFingerprints() {
        launchApp(reset: true)

        openEditorForNewConnection()
        app.buttons["key-selector"].tap()

        XCTAssertTrue(app.buttons["key-Fixture-Ed25519"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["key-Fixture-Ed25519-Passphrase"].exists)
        XCTAssertTrue(app.buttons["key-Fixture-Hop2-Unauthorized"].exists)

        let fingerprintTexts = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'SHA256:'")
        )
        XCTAssertGreaterThanOrEqual(fingerprintTexts.count, 3)

        XCTAssertTrue(
            app.staticTexts["SHA256:+r0XE2pE/ZCcOeGWrisHbWLLrEFKapNtuqH9LUZ7QqU"].exists,
            "deterministic fixture fingerprint must be shown"
        )

        app.buttons["key-Fixture-Ed25519"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Ed25519"].waitForExistence(timeout: 5),
                      "selected key label must appear on the key row")
    }

    // MARK: Swipe actions — edit / duplicate / delete

    func testSwipeActionsEditDuplicateAndDelete() {
        launchApp(reset: true)

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Swipe Me")
        typeInto(app.textFields["field-host"], "10.9.9.9")
        typeInto(app.textFields["field-username"], "u")
        selectAuthenticationKey("Fixture Ed25519")
        app.buttons["save-editor"].tap()

        let original = app.buttons["connection-Swipe-Me"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))

        swipeRow(named: "Swipe-Me")
        let edit = app.buttons["edit-Swipe-Me"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 5))
        app.buttons["cancel-editor"].tap()

        swipeRow(named: "Swipe-Me")
        let duplicate = app.buttons["duplicate-Swipe-Me"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()
        XCTAssertTrue(app.buttons["connection-Swipe-Me-(copy)"].waitForExistence(timeout: 10))

        swipeRow(named: "Swipe-Me-(copy)")
        let delete = app.buttons["delete-Swipe-Me-(copy)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let copyGone = NSPredicate(format: "exists == false")
        expectation(for: copyGone, evaluatedWith: app.buttons["connection-Swipe-Me-(copy)"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(original.waitForExistence(timeout: 5), "original must survive deleting the copy")
    }

    func testUnavailablePersistedProtocolRemainsVisibleAndCannotBeSavedOrConnected() {
        app.launchArguments = ["--uitest-unavailable-connection"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Unavailable"].waitForExistence(timeout: 10))
        let row = app.buttons["connection-Future-Protocol"]
        XCTAssertTrue(row.exists, "known persisted protocols must not disappear when their descriptor is unavailable")
        XCTAssertTrue(app.staticTexts["unavailable-Future-Protocol"].exists)

        row.tap()
        XCTAssertTrue(app.staticTexts["This protocol isn't available in this build"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-editor"].isEnabled)
        XCTAssertFalse(app.buttons["connect-button"].isEnabled)
        app.buttons["protocol-picker"].tap()
        XCTAssertTrue(app.buttons["uppercase-echo (Unavailable)"].waitForExistence(timeout: 5))
    }

    func testFailedPersistenceKeepsEditorOpenAndClearsErrorAfterEditing() {
        app.launchArguments = ["--uitest-seed-keys", "--uitest-fail-persistence"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Cannot Save")
        typeInto(app.textFields["field-host"], "failure.example.com")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")
        app.buttons["connect-button"].tap()

        let error = app.staticTexts["save-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Check available storage and try again"))
        XCTAssertTrue(app.textFields["field-name"].exists, "a failed write must keep the editor open")

        typeInto(app.textFields["field-name"], " Retry", clearing: nil)
        XCTAssertFalse(error.exists, "editing before a retry must clear the stale save error")
    }

    // MARK: Helpers

    private func launchApp(reset: Bool) {
        app.launchArguments = reset ? ["--uitest-reset"] : []
        app.launch()
    }

    private func openEditorForNewConnection() {
        let add = app.buttons["add-connection"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
    }

    private func typeInto(_ field: XCUIElement, _ text: String, clearing existing: String? = nil) {
        field.tap()
        if let existing {
            field.typeText(String(repeating: "\u{8}", count: existing.count + 2))
        }
        field.typeText(text)
        dismissKeyboard()
    }

    private func dismissKeyboard() {
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

    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 5) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        app.buttons["key-selector"].tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
    }

    private func addHop(host: String, port: String?, username: String, key: String) {
        let addHopButton = app.buttons["add-hop"]
        scrollToHittable(addHopButton)
        addHopButton.tap()

        let hostField = app.textFields["hop-field-host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        typeInto(hostField, host)
        if let port {
            let portField = app.textFields["hop-field-port"]
            typeInto(portField, port, clearing: "22")
        }
        typeInto(app.textFields["hop-field-username"], username)

        app.buttons["hop-key-selector"].tap()
        let keyButton = app.buttons["key-\(key.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(keyButton.waitForExistence(timeout: 5))
        keyButton.tap()

        let save = app.buttons["save-hop"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.buttons["add-hop"].waitForExistence(timeout: 10), "hop sheet must close after save")
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
