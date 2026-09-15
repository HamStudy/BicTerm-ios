import XCTest

@MainActor
final class ConnectionEditorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testReplacingDefaultPortDoesNotAppendToExistingDigits() {
        launchApp(reset: true)
        openEditorForNewConnection()
        let port = app.textFields["field-port"]

        port.tap()
        awaitKeyboardFocus(on: port)
        capturePortState("port-keyboard-focused")

        typeInto(port, "12222", clearing: "22")

        XCTAssertEqual(port.value as? String, "12222")
        capturePortState("port-value-replaced")
    }

    private func capturePortState(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

        let relaunchedRow = app.buttons["connection-Chain-Two-Hop"]
        XCTAssertTrue(relaunchedRow.waitForExistence(timeout: 10), "connection must survive relaunch")
        XCTAssertTrue(app.staticTexts["2 hops"].exists)

        openEditorForConnection(named: "Chain-Two-Hop")

        let nameField = app.textFields["field-name"]
        scrollToHittable(nameField, swipingUp: false)
        XCTAssertTrue(nameField.isHittable)
        XCTAssertEqual(nameField.value as? String, "Chain Two Hop")
        XCTAssertEqual(app.textFields["field-host"].value as? String, "10.0.0.9")
        XCTAssertEqual(app.textFields["field-username"].value as? String, "alice")

        let keySelector = app.buttons["key-selector"]
        scrollToHittable(keySelector)
        XCTAssertTrue(keySelector.label.contains("1 selected keys"),
                      "editor must reopen with the custom key count")

        let firstHop = app.staticTexts["hop-0-host"]
        scrollToHittable(firstHop)
        XCTAssertEqual(firstHop.label, "127.0.0.1:12222")
        XCTAssertEqual(app.staticTexts["hop-1-host"].label, "127.0.0.1:12223")

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

        let addHop = app.buttons["add-hop"]
        scrollToHittable(addHop)
        XCTAssertTrue(addHop.isHittable)
        addHop.tap()
        XCTAssertTrue(app.staticTexts["hop-limit-message"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hop-limit-message"].label, "Maximum 5 hops")
        XCTAssertFalse(app.textFields["hop-field-host"].exists, "6th hop editor must not open")

        let hostField = app.textFields["field-host"]
        scrollToHittable(hostField, swipingUp: false)
        typeInto(hostField, "hop1.example.com", clearing: "10.1.2.3")
        let cycleWarning = app.staticTexts["cycle-warning"]
        scrollToHittable(cycleWarning)
        XCTAssertTrue(cycleWarning.isHittable)
        XCTAssertFalse(app.buttons["save-editor"].isEnabled, "save must be disabled for a cyclic chain")

        scrollToHittable(hostField, swipingUp: false)
        typeInto(hostField, "10.1.2.3", clearing: "hop1.example.com")
        scrollToHittable(addHop)
        XCTAssertFalse(cycleWarning.exists)
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
        XCTAssertNotEqual(app.buttons["key-Fixture-Ed25519"].value as? String, "Selected")
    }

    // MARK: Key picker — inline generate/import/copy + live list

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let unencryptedFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519")

    /// Wipes every keychain key through the existing `-uitest-reset-keys`
    /// seam (activated by the key-management cover), then dismisses the
    /// cover so the connection list is reachable.
    private func launchWithNoKeys(extraArguments: [String] = []) {
        app.launchArguments = ["-uitest-keys-entry", "-uitest-reset-keys"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.navigationBars["SSH Keys"].waitForExistence(timeout: 15),
            "Key management entry did not appear"
        )
        app.buttons["keys-done"].tap()
        XCTAssertTrue(app.buttons["add-connection"].waitForExistence(timeout: 10))
    }

    private func openKeyPickerForNewConnection() {
        openEditorForNewConnection()
        app.buttons["key-selector"].tap()
        XCTAssertTrue(
            app.navigationBars["Customize Keys"].waitForExistence(timeout: 5),
            "Key picker did not open"
        )
    }

    func testKeyPickerEmptyStateOffersGenerateAndImport() {
        launchWithNoKeys()
        openKeyPickerForNewConnection()

        XCTAssertTrue(
            app.descendants(matching: .any)["picker-empty-state"].waitForExistence(timeout: 5),
            "Empty state must replace the inert text"
        )
        XCTAssertTrue(app.buttons["picker-empty-generate"].exists, "Empty state must offer Generate Key")
        XCTAssertTrue(app.buttons["picker-empty-import"].exists, "Empty state must offer Import Key")
        XCTAssertTrue(app.buttons["picker-add-menu"].exists, "Toolbar add menu must exist in the empty state")
        XCTAssertTrue(app.buttons["use-all-enabled-keys"].exists, "An empty pool must still allow returning to inheritance")
    }

    func testGenerateKeyInlineAutoSelectsInEditor() {
        launchWithNoKeys(extraArguments: ["-uitest-biometrics-bypass"])
        openKeyPickerForNewConnection()

        app.buttons["picker-empty-generate"].tap()
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5), "Generate sheet must open over the picker")
        typeInto(labelField, "Inline Key")
        XCTAssertTrue(setToggle(app.switches["generate-biometrics"], on: false))

        app.buttons["generate-save"].tap()

        let keySelector = app.buttons["key-selector"]
        XCTAssertTrue(
            keySelector.waitForExistence(timeout: 10),
            "Saving a key inline must auto-select it and return to the editor"
        )
        XCTAssertTrue(
            keySelector.label.contains("1 offered"),
            "Editor key row must show the inline-generated key, got: \(keySelector.label)"
        )
    }

    func testImportKeyInlineAutoSelectsInEditor() {
        launchWithNoKeys(extraArguments: ["-uitest-seed-pasteboard", Self.unencryptedFixture.path])
        openKeyPickerForNewConnection()

        app.buttons["picker-empty-import"].tap()
        let labelField = app.textFields["import-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5), "Import sheet must open over the picker")
        typeInto(labelField, "Inline Import")

        app.buttons["import-paste"].tap()
        let status = app.staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(
            status.label.contains("unencrypted"),
            "Seeded fixture must parse without a passphrase, got: \(status.label)"
        )

        app.buttons["import-save"].tap()

        let keySelector = app.buttons["key-selector"]
        XCTAssertTrue(
            keySelector.waitForExistence(timeout: 10),
            "Saving an imported key inline must auto-select it and return to the editor"
        )
        XCTAssertTrue(
            keySelector.label.contains("1 offered"),
            "Editor key row must show the inline-imported key, got: \(keySelector.label)"
        )
    }

    func testCopyPublicKeyFromPickerShowsConfirmation() {
        launchApp(reset: true)
        openKeyPickerForNewConnection()

        let row = app.buttons["key-Fixture-Ed25519"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)

        let copyByIdentifier = app.buttons["copy-key-Fixture-Ed25519"]
        let copyItem = copyByIdentifier.exists ? copyByIdentifier : app.buttons["Copy Public Key"]
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5), "Row context menu must offer Copy Public Key")
        copyItem.tap()

        let confirmation = app.staticTexts["copy-confirmation"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Copy must surface app-observable confirmation state in the picker"
        )
        XCTAssertEqual(
            confirmation.label, "Copied public key",
            "Copy round-trip verification failed inside the app"
        )
    }

    func testKeyPickerShowsCheckmarkForCurrentlySelectedKey() {
        launchApp(reset: true)
        openEditorForNewConnection()
        selectAuthenticationKey("Fixture Ed25519")

        app.buttons["key-selector"].tap()
        XCTAssertTrue(app.navigationBars["Customize Keys"].waitForExistence(timeout: 5))

        let selected = app.buttons["key-Fixture-Ed25519"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertEqual(
            selected.value as? String, "Selected",
            "The connection editor's current key must read as selected in the picker"
        )
        XCTAssertNotEqual(
            app.buttons["key-Fixture-Hop2-Unauthorized"].value as? String, "Selected",
            "Unselected keys must not read as selected"
        )
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

        // Duplicate opens the editor as a pre-filled add flow; nothing
        // persists until Save.
        swipeRow(named: "Swipe-Me")
        let duplicate = app.buttons["duplicate-Swipe-Me"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["connection-editor"].waitForExistence(timeout: 10),
            "duplicate must open the connection editor"
        )
        XCTAssertTrue(app.navigationBars["New Connection"].exists,
                      "duplicate must behave as the add flow, not an edit")
        let nameField = app.textFields["field-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Swipe Me (copy)")
        XCTAssertEqual(app.textFields["field-host"].value as? String, "10.9.9.9")
        XCTAssertEqual(app.textFields["field-port"].value as? String, "22")
        XCTAssertEqual(app.textFields["field-username"].value as? String, "u")
        XCTAssertTrue(
            app.buttons["key-selector"].label.contains("1 selected keys"),
            "duplicate must carry the source's key selection"
        )
        XCTAssertTrue(app.buttons["save-editor"].isEnabled,
                      "a pre-filled duplicate draft must be valid without further input")
        XCTAssertFalse(app.buttons["connection-Swipe-Me-(copy)"].exists,
                       "duplicating must not persist a row before Save")

        // The pre-filled draft is the dirty-check baseline, so cancelling an
        // untouched duplicate dismisses without a prompt and adds no row.
        app.buttons["cancel-editor"].tap()
        let editorGone = NSPredicate(format: "exists == false")
        expectation(for: editorGone, evaluatedWith: app.buttons["cancel-editor"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(
            app.descendants(matching: .any)["discard-changes-dialog"].exists,
            "an untouched duplicate draft must cancel without prompting"
        )
        XCTAssertFalse(app.buttons["connection-Swipe-Me-(copy)"].exists,
                       "cancel must discard the duplicate — no new row")
        XCTAssertTrue(original.exists)

        // Saving the pre-filled editor persists exactly one new row.
        swipeRow(named: "Swipe-Me")
        XCTAssertTrue(app.buttons["duplicate-Swipe-Me"].waitForExistence(timeout: 5))
        app.buttons["duplicate-Swipe-Me"].tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 5))
        app.buttons["save-editor"].tap()

        let copy = app.buttons["connection-Swipe-Me-(copy)"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.buttons.matching(identifier: "connection-Swipe-Me-(copy)").count, 1,
            "save must insert exactly one new row"
        )
        XCTAssertTrue(original.exists, "the source row must survive duplicating")

        swipeRow(named: "Swipe-Me-(copy)")
        let delete = app.buttons["delete-Swipe-Me-(copy)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["confirm-delete-connection"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "connection deletes ask for confirmation"
        )
        confirm.tap()
        let copyGone = NSPredicate(format: "exists == false")
        expectation(for: copyGone, evaluatedWith: app.buttons["connection-Swipe-Me-(copy)"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(original.waitForExistence(timeout: 5), "original must survive deleting the copy")
    }

    // MARK: Row tap — default tap connects, swipe menu keeps edit

    func testTappingConnectionRowOpensSession() {
        app.launchArguments = ["--uitest-reset", "--uitest-demo"]
        app.launch()

        let row = app.buttons["connection-Demo-Jump-Chain"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        swipeRow(named: "Demo-Jump-Chain")
        XCTAssertTrue(app.buttons["edit-Demo-Jump-Chain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connect-Demo-Jump-Chain"].exists)

        app.terminate()
        app.launch()

        let relaunchedRow = app.buttons["connection-Demo-Jump-Chain"]
        XCTAssertTrue(relaunchedRow.waitForExistence(timeout: 15))
        relaunchedRow.tap()

        XCTAssertTrue(app.staticTexts["scene-title-Demo-Jump-Chain"].waitForExistence(timeout: 10),
                      "tapping a row must open a session scene for that connection")
        XCTAssertTrue(app.buttons["scene-close-Demo-Jump-Chain"].exists)
        XCTAssertFalse(app.textFields["field-name"].exists,
                       "tapping a row must not open the editor")
    }

    func testUnavailablePersistedProtocolRemainsVisibleAndCannotBeSavedOrConnected() {
        app.launchArguments = ["--uitest-unavailable-connection"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Unavailable"].waitForExistence(timeout: 10))
        let row = app.buttons["connection-Future-Protocol"]
        XCTAssertTrue(row.exists, "known persisted protocols must not disappear when their descriptor is unavailable")
        XCTAssertTrue(app.staticTexts["unavailable-Future-Protocol"].exists)

        openEditorForConnection(named: "Future-Protocol")
        let unavailableMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "This protocol isn't available in this build")
        ).firstMatch
        XCTAssertTrue(unavailableMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(unavailableMessage.isHittable)
        XCTAssertFalse(app.buttons["save-editor"].isEnabled)
        app.buttons["protocol-picker"].tap()
        let unavailableChoice = app.buttons["uppercase-echo (Unavailable)"]
        XCTAssertTrue(unavailableChoice.waitForExistence(timeout: 5))
        unavailableChoice.tap()

        let connect = app.buttons["connect-button"]
        scrollToHittable(connect)
        XCTAssertTrue(connect.isHittable)
        XCTAssertFalse(connect.isEnabled)
    }

    func testFailedPersistenceKeepsEditorOpenAndClearsErrorAfterEditing() {
        app.launchArguments = ["--uitest-seed-keys", "--uitest-fail-persistence"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Cannot Save")
        typeInto(app.textFields["field-host"], "failure.example.com")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")
        let connectButton = app.buttons["connect-button"]
        scrollToHittable(connectButton)
        connectButton.tap()

        let error = app.staticTexts["save-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Check available storage and try again"))
        XCTAssertTrue(app.buttons["cancel-editor"].exists, "a failed write must keep the editor open")

        let nameField = app.textFields["field-name"]
        scrollToHittable(nameField, swipingUp: false)
        XCTAssertTrue(nameField.isHittable)
        typeInto(nameField, " Retry", clearing: nil)
        XCTAssertFalse(error.exists, "editing before a retry must clear the stale save error")
    }

    // MARK: Dirty-draft discard confirmation

    func testDirtyNewConnectionCancelPromptsAndDiscards() {
        launchApp(reset: true)
        openEditorForNewConnection()
        typeInto(app.textFields["field-host"], "dirty.example.com")

        app.buttons["cancel-editor"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5),
            "cancelling a dirty draft must prompt before losing it"
        )
        XCTAssertTrue(app.staticTexts["Discard Changes?"].exists)

        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()

        let editorGone = NSPredicate(format: "exists == false")
        expectation(for: editorGone, evaluatedWith: app.buttons["cancel-editor"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["connection-dirty"].exists, "a discarded draft must not persist")
    }

    func testDirtyNewConnectionKeepEditingPreservesDraft() {
        launchApp(reset: true)
        openEditorForNewConnection()
        typeInto(app.textFields["field-host"], "keep.example.com")

        app.buttons["cancel-editor"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5),
            "cancelling a dirty draft must prompt"
        )
        dialogButton(identifier: "discard-cancel", label: "Keep Editing").tap()

        let host = app.textFields["field-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "Keep Editing must stay in the editor")
        XCTAssertEqual(host.value as? String, "keep.example.com", "Keep Editing must preserve the draft")

        app.buttons["cancel-editor"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5))
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
    }

    func testCleanExistingConnectionCancelsWithoutPrompting() {
        app.launchArguments = ["--uitest-reset", "--uitest-demo"]
        app.launch()
        openEditorForConnection(named: "Demo-Jump-Chain")

        app.buttons["cancel-editor"].tap()

        let editorGone = NSPredicate(format: "exists == false")
        expectation(for: editorGone, evaluatedWith: app.buttons["cancel-editor"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(
            app.descendants(matching: .any)["discard-changes-dialog"].exists,
            "an untouched draft must never show the discard dialog"
        )
        XCTAssertFalse(app.staticTexts["Discard Changes?"].exists)
    }

    func testDirtyHopEditorCancelPromptsAndDiscards() {
        launchApp(reset: true)
        openEditorForNewConnection()

        let addHop = app.buttons["add-hop"]
        scrollToHittable(addHop)
        addHop.tap()
        let hostField = app.textFields["hop-field-host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        typeInto(hostField, "hop.example.com")

        app.buttons["cancel-hop"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5),
            "cancelling a dirty hop draft must prompt"
        )
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()

        let popped = NSPredicate(format: "exists == false")
        expectation(for: popped, evaluatedWith: hostField)
        waitForExpectations(timeout: 10)
        scrollToHittable(app.textFields["field-name"], swipingUp: false)
        XCTAssertTrue(
            app.textFields["field-name"].waitForExistence(timeout: 5),
            "discarding the hop must return to the connection editor"
        )
        XCTAssertFalse(app.staticTexts["hop-0-host"].exists, "a discarded hop must not enter the draft")

        app.buttons["cancel-editor"].tap()
    }

    // MARK: Hop push — draft survives the pop

    func testSavedHopPushPreservesConnectionDraft() {
        launchApp(reset: true)

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Draft Keeper")
        typeInto(app.textFields["field-host"], "10.20.30.40")
        typeInto(app.textFields["field-username"], "carol")
        selectAuthenticationKey("Fixture Ed25519")
        app.buttons["save-editor"].tap()

        XCTAssertTrue(app.buttons["connection-Draft-Keeper"].waitForExistence(timeout: 10))
        openEditorForConnection(named: "Draft-Keeper")

        addHop(host: "127.0.0.1", port: "12222", username: "hopuser", key: "Fixture Ed25519")

        // Saving the hop pops the pushed editor back onto the same editor
        // instance — the stack kept it alive, so the in-progress draft and
        // its field values must be exactly as they were before the push.
        XCTAssertTrue(app.staticTexts["hop-0-host"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hop-0-host"].label, "127.0.0.1:12222")

        let nameField = app.textFields["field-name"]
        scrollToHittable(nameField, swipingUp: false)
        XCTAssertEqual(nameField.value as? String, "Draft Keeper")
        XCTAssertEqual(app.textFields["field-host"].value as? String, "10.20.30.40")
        XCTAssertEqual(app.textFields["field-username"].value as? String, "carol")

        // The saved hop lives only in the editor's in-memory draft until the
        // connection itself is saved, so cancelling here must still prompt.
        app.buttons["cancel-editor"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5))
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
    }

    /// SwiftUI confirmationDialog actions surface under their SwiftUI
    /// accessibilityIdentifier or their visible label depending on the OS
    /// bridge; match either.
    private func dialogButton(identifier: String, label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        let button = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "dialog action \(label) must exist")
        return button
    }

    // MARK: Validation timing — no red on pristine blank forms

    /// A freshly opened editor must not flag required-but-empty fields;
    /// the inline error arms only after the field is edited (or a save is
    /// attempted, which stays gated off while the draft is invalid).
    func testBlankConnectionFormShowsNoFieldErrorsUntilEdited() {
        launchApp(reset: true)
        openEditorForNewConnection()

        XCTAssertFalse(app.staticTexts["field-name-error"].exists,
                       "a pristine blank form must not flag the name field")
        XCTAssertFalse(app.staticTexts["field-host-error"].exists,
                       "a pristine blank form must not flag the host field")
        XCTAssertFalse(app.staticTexts["field-username-error"].exists,
                       "a pristine blank form must not flag the username field")

        typeInto(app.textFields["field-host"], "bad_host")
        let hostError = app.staticTexts["field-host-error"]
        XCTAssertTrue(hostError.waitForExistence(timeout: 5),
                      "editing a field must arm its inline error")
        XCTAssertEqual(hostError.label, "Invalid hostname")
    }

    func testBlankHopFormShowsNoFieldErrorsUntilEdited() {
        launchApp(reset: true)
        openEditorForNewConnection()

        let addHop = app.buttons["add-hop"]
        scrollToHittable(addHop)
        addHop.tap()

        let hostField = app.textFields["hop-field-host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["hop-field-host-error"].exists,
                       "a pristine blank hop must not flag the host field")
        XCTAssertFalse(app.staticTexts["hop-field-username-error"].exists,
                       "a pristine blank hop must not flag the username field")

        typeInto(hostField, "bad_host")
        XCTAssertTrue(app.staticTexts["hop-field-host-error"].waitForExistence(timeout: 5),
                      "editing a hop field must arm its inline error")

        app.buttons["cancel-hop"].tap()
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
        scrollToHittable(app.textFields["field-name"], swipingUp: false)
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 5),
                      "discarding the hop must return to the connection editor")

        app.buttons["cancel-editor"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["discard-changes-dialog"].exists,
                       "the parent draft was never touched — no discard prompt")
    }

    // MARK: Helpers

    func testOfferKeysTogglePreservesStateAndDisablesCustomize() {
        launchApp(reset: true)
        openEditorForNewConnection()
        selectAuthenticationKey("Fixture Ed25519")
        let password = app.secureTextFields["password-field"]
        scrollToHittable(password)
        typeInto(password, "kept-password")
        let toggle = app.switches["offer-keys-toggle"]
        scrollToHittable(toggle, swipingUp: false)
        XCTAssertTrue(setToggle(toggle, on: false))
        XCTAssertFalse(app.buttons["key-selector"].isEnabled)
        XCTAssertEqual(password.value as? String, String(repeating: "•", count: 13))
        XCTAssertTrue(setToggle(toggle, on: true))
        XCTAssertTrue(app.buttons["key-selector"].isEnabled)
        app.buttons["key-selector"].tap()
        XCTAssertEqual(app.buttons["key-Fixture-Ed25519"].value as? String, "Selected")
        XCTAssertNotEqual(app.buttons["key-Fixture-Hop2-Unauthorized"].value as? String, "Selected")
        capturePortState("offer-keys-customization-preserved")
    }

    func testUseAllEnabledKeysClearsCustomSelection() {
        app.launchArguments = ["-uitest-reset-keys", "--uitest-reset", "-uitest-seed-se-key"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(setToggle(app.switches["settings-hardware-keys"], on: false))
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        openKeyPickerForNewConnection()
        XCTAssertEqual(app.buttons["key-Fixture-Ed25519"].value as? String, "Selected")
        XCTAssertNotEqual(app.buttons["key-SE-Test-Key"].value as? String, "Selected")
        app.buttons["key-Fixture-Ed25519"].tap()
        XCTAssertEqual(app.staticTexts["key-selection-mode"].label, "Custom selection")
        app.buttons["key-Fixture-Ed25519"].tap()
        XCTAssertEqual(app.staticTexts["key-selection-mode"].label, "Using inherited keys")
        app.buttons["key-SE-Test-Key"].tap()
        XCTAssertEqual(app.buttons["key-SE-Test-Key"].value as? String, "Selected")
        XCTAssertEqual(app.staticTexts["key-selection-mode"].label, "Custom selection")
        capturePortState("customize-explicit-hardware-key")
        app.buttons["use-all-enabled-keys"].tap()
        XCTAssertNotEqual(app.buttons["key-SE-Test-Key"].value as? String, "Selected")
        XCTAssertEqual(app.staticTexts["key-selection-mode"].label, "Using inherited keys")
    }

    func testDisabledRetainedKeyShowsDisabledBadge() {
        app.launchArguments = ["-uitest-reset-keys", "--uitest-reset", "-uitest-seed-disabled-key",
                               "--uitest-custom-disabled"]
        app.launch()
        openEditorForConnection(named: "Disabled-Custom")
        app.buttons["key-selector"].tap()
        let row = app.buttons["key-Disabled-Fixture"]
        XCTAssertEqual(row.value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["disabled-key-badge"].exists)
        row.tap()
        XCTAssertNotEqual(row.value as? String, "Selected")
        XCTAssertFalse(row.isEnabled)
    }

    func testReplacementAfterStagedRemovalSavesAndConnectsWithoutPrompting() {
        launchPasswordFixture("both")
        stagePasswordRemoval()
        let password = app.secureTextFields["password-field"]
        scrollToHittable(password, swipingUp: false)
        typeInto(password, "bicterm-uitest-fixture-password")
        savePasswordFixture()
        connectPasswordFixture(expectPrompt: false)
    }

    func testPromptOnlyTagDeletedAfterSave() {
        launchPasswordFixture("prompted")
        stagePasswordRemoval()
        savePasswordFixture()
        connectPasswordFixture(expectPrompt: true)
    }

    func testBothPasswordTagsDeletedAfterSave() {
        launchPasswordFixture("both")
        stagePasswordRemoval()
        savePasswordFixture()
        connectPasswordFixture(expectPrompt: true)
    }

    func testHopSharedTagRetainedAfterSave() {
        launchPasswordFixture("hop-shared")
        stagePasswordRemoval()
        savePasswordFixture()
        openEditorForConnection(named: "Credential-Fixture")
        assertHopPasswordSaved()
    }

    func testOtherConnectionHopTagRetained() {
        launchPasswordFixture("other-hop")
        stagePasswordRemoval()
        savePasswordFixture()
        openEditorForConnection(named: "Other-Hop")
        assertHopPasswordSaved()
    }

    func testCancelledRemovalPreservesSavedPassword() {
        launchPasswordFixture("both")
        stagePasswordRemoval()
        app.buttons["cancel-editor"].tap()
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
        connectPasswordFixture(expectPrompt: false)
    }

    func testSaveFailurePreservesCredentials() {
        launchPasswordFixture("both", extra: ["--uitest-editor-save-fail"])
        stagePasswordRemoval()
        app.buttons["save-editor"].tap()
        let error = app.staticTexts["save-error"]
        scrollToHittable(error)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--uitest-pwd-server", "--uitest-pretrust-fixtures"]
        app.launch()
        connectPasswordFixture(expectPrompt: false)
    }

    func testDuplicateSharedPasswordSurvivesRemoval() {
        launchPasswordFixture("saved")
        app.buttons["cancel-editor"].tap()
        swipeRow(named: "Credential-Fixture")
        app.buttons["duplicate-Credential-Fixture"].tap()
        XCTAssertTrue(app.buttons["save-editor"].waitForExistence(timeout: 5))
        app.buttons["save-editor"].tap()
        XCTAssertTrue(app.buttons["connection-Credential-Fixture-(copy)"].waitForExistence(timeout: 5))
        openEditorForConnection(named: "Credential-Fixture")
        stagePasswordRemoval()
        savePasswordFixture()
        connectPasswordFixture(expectPrompt: false, name: "Credential-Fixture-(copy)")
    }

    func testStagedRemovalCancelledByReplacementInput() {
        launchPasswordFixture("saved")
        stagePasswordRemoval()
        let password = app.secureTextFields["password-field"]
        scrollToHittable(password, swipingUp: false)
        typeInto(password, "bicterm-uitest-fixture-password")
        XCTAssertFalse(app.staticTexts["password-removal-status"].exists)
        XCTAssertTrue(app.staticTexts["password-field-status"].label.contains("Will be saved"))
        savePasswordFixture()
        openEditorForConnection(named: "Credential-Fixture")
        let badge = app.staticTexts["password-saved-badge"]
        scrollToHittable(badge)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
    }

    func testOfferCountWarningUsesEffectiveResolverCount() {
        app.launchArguments = ["-uitest-reset-keys", "--uitest-reset", "-uitest-seed-offer-warning",
                               "-uitest-seed-disabled-key"]
        app.launch()
        openEditorForNewConnection()
        let warning = app.staticTexts["offer-count-warning"]
        scrollToHittable(warning)
        XCTAssertEqual(warning.label, "6 keys will be offered. Many servers allow only 6 authentication attempts and may disconnect before later keys are tried.")
        capturePortState("six-key-offer-warning")
        let toggle = app.switches["offer-keys-toggle"]
        scrollToHittable(toggle, swipingUp: false)
        XCTAssertTrue(setToggle(toggle, on: false))
        XCTAssertFalse(warning.exists)
        XCTAssertTrue(setToggle(toggle, on: true))
        app.buttons["key-selector"].tap()
        app.buttons["key-Fixture-Ed25519"].tap()
        app.buttons["customize-done"].tap()
        XCTAssertFalse(warning.exists)
    }

    private func launchPasswordFixture(_ mode: String, extra: [String] = []) {
        app.launchArguments = ["--uitest-reset", "--uitest-pwd-server", "--uitest-pretrust-fixtures",
                               "--uitest-editor-password-fixture", mode] + extra
        app.launch()
        XCTAssertTrue(app.buttons["connection-Credential-Fixture"].waitForExistence(timeout: 15))
        openEditorForConnection(named: "Credential-Fixture")
    }

    private func stagePasswordRemoval() {
        let remove = app.buttons["remove-saved-password"]
        scrollToHittable(remove)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.staticTexts["password-removal-status"].exists)
    }

    private func savePasswordFixture() {
        app.buttons["save-editor"].tap()
        XCTAssertTrue(app.buttons["connection-Credential-Fixture"].waitForExistence(timeout: 10))
    }

    private func connectPasswordFixture(expectPrompt: Bool, name: String = "Credential-Fixture") {
        let row = app.buttons["connection-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        if app.buttons["trust-confirm"].waitForExistence(timeout: 3) { app.buttons["trust-confirm"].tap() }
        if expectPrompt {
            XCTAssertTrue(app.secureTextFields["password-prompt-field"].waitForExistence(timeout: 15))
        } else {
            let status = app.staticTexts["scene-statuschip-\(name)"]
            expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: status)
            waitForExpectations(timeout: 15)
            XCTAssertFalse(app.secureTextFields["password-prompt-field"].exists)
        }
    }

    private func assertHopPasswordSaved() {
        let edit = app.buttons["edit-hop-0"]
        scrollToHittable(edit)
        edit.tap()
        let badge = app.staticTexts["hop-password-saved-badge"]
        scrollToHittable(badge)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
    }

    private func launchApp(reset: Bool) {
        app.launchArguments = reset ? ["-uitest-reset-keys", "--uitest-reset"] : []
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

    private func typeInto(_ field: XCUIElement, _ text: String, clearing existing: String? = nil) {
        field.tap()
        awaitKeyboardFocus(on: field)
        if existing != nil {
            selectAllForReplacement(of: field)
        }
        app.typeText(text)
        dismissKeyboard()
    }

    /// isHittable flaps during keyboard/Form relayout; the stable, meaningful
    /// predicate for text entry is focus ownership itself.
    private func awaitKeyboardFocus(on field: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: timeout)
    }

    /// Caret/alignment-agnostic clear: select all content through the edit
    /// menu; the following app-level typeText then replaces the selection
    /// wholesale regardless of caret position or deleted-keystroke delivery.
    private func selectAllForReplacement(of field: XCUIElement) {
        field.press(forDuration: 1.1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        }
    }

    private func dismissKeyboard() {
        // An absent keyboard must turn this into a no-op: the drag fallback is
        // itself a focus-disturbing full-form gesture.
        guard app.keyboards.count > 0 else { return }
        let toolbarDone = app.toolbars.buttons["Done"]
        let plainDone = app.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        if plainDone.exists && plainDone.isHittable && plainDone.identifier != "customize-done" {
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

    /// A Form row straddling the window edge still reports `isHittable`, but
    /// XCUI computes the synthetic tap at the row's centre; when the row is
    /// clipped below the window the tap lands in the home-indicator band and
    /// never reaches the control (observed: sixth `add-hop` tap did nothing);
    /// rows clipped under the navigation bar fail the same way (taps hit the
    /// bar's backdrop layer — `field-name` never gained focus).
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

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        let selector = app.buttons["key-selector"]
        scrollToHittable(selector)
        selector.tap()
        selectOnlyKey(label)
        app.buttons["customize-done"].tap()
    }

    private func selectOnlyKey(_ label: String) {
        let identifier = "key-\(label.replacingOccurrences(of: " ", with: "-"))"
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'key-' AND identifier != 'key-selection-mode'"))
        for row in rows.allElementsBoundByIndex {
            let desired = row.identifier == identifier
            if (row.value as? String == "Selected") != desired, row.isEnabled { row.tap() }
        }
    }

    /// A SwiftUI Form Toggle's XCUI element spans the whole row; tapping its
    /// center hits the label, which does NOT flip the switch. Taps land on the
    /// trailing edge (where the switch renders) after revealing the row.
    @discardableResult
    private func setToggle(_ element: XCUIElement, on: Bool) -> Bool {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Toggle \(element) missing")
        func isOn() -> Bool {
            let value = (element.value as? String ?? "").lowercased()
            return value == "1" || value == "true" || value == "on"
        }
        var swipes = 0
        while isOn() != on {
            if !element.isHittable, swipes < 3 {
                app.swipeUp()
                swipes += 1
                continue
            }
            guard swipes < 6 else { return false }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            swipes += 1
        }
        return true
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
        selectOnlyKey(key)
        app.buttons["customize-done"].tap()

        let save = app.buttons["save-hop"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        let popped = NSPredicate(format: "exists == false")
        expectation(for: popped, evaluatedWith: hostField)
        waitForExpectations(timeout: 10)

        // The hop editor is pushed, not sheeted: saving pops it back onto the
        // connection editor. A tap issued while the pop transition is still
        // unwinding lands on the sliding-away view and is swallowed; gate on
        // the editor's chrome being interactive again before the next hop.
        let editorReady = NSPredicate(format: "hittable == true")
        expectation(for: editorReady, evaluatedWith: app.buttons["cancel-editor"])
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 0.4)
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
