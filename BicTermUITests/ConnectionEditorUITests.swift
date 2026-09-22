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
        openKeyPicker()

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
        openKeyPicker()
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
        // The sheet is still animating in when its fields enter the AX
        // hierarchy; a tap synthesized mid-presentation is swallowed and the
        // keyboard-focus wait below would fail.
        awaitHittable(labelField)
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
        awaitHittable(labelField)
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
        awaitHittable(edit)
        edit.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 5))
        awaitConnectionEditorInteractive()
        app.buttons["cancel-editor"].tap()

        // Duplicate opens the editor as a pre-filled add flow; nothing
        // persists until Save.
        swipeRow(named: "Swipe-Me")
        let duplicate = app.buttons["duplicate-Swipe-Me"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        awaitHittable(duplicate)
        duplicate.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["connection-editor"].waitForExistence(timeout: 10),
            "duplicate must open the connection editor"
        )
        awaitConnectionEditorInteractive()
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
        awaitHittable(app.buttons["duplicate-Swipe-Me"])
        app.buttons["duplicate-Swipe-Me"].tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 5))
        awaitConnectionEditorInteractive()
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
        awaitHittable(delete)
        delete.tap()
        let confirm = app.buttons["confirm-delete-connection"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "connection deletes ask for confirmation"
        )
        awaitHittable(confirm)
        confirm.tap()
        let copyGone = NSPredicate(format: "exists == false")
        expectation(for: copyGone, evaluatedWith: app.buttons["connection-Swipe-Me-(copy)"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(original.waitForExistence(timeout: 5), "original must survive deleting the copy")
    }

    // MARK: Context menu — pointer secondary click / touch long press

    /// XCUITest has no iOS secondary-click primitive; a long press opens the
    /// same native UIContextMenuInteraction that a pointer secondary click
    /// opens on iPadOS, so this path verifies the shared menu content.
    func testContextMenuExposesRowActions() {
        launchApp(reset: true)

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Menu Me")
        typeInto(app.textFields["field-host"], "10.9.9.8")
        typeInto(app.textFields["field-username"], "u")
        selectAuthenticationKey("Fixture Ed25519")
        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Menu-Me"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.press(forDuration: 1.1)

        XCTAssertTrue(
            app.buttons["connect-Menu-Me"].waitForExistence(timeout: 5),
            "context menu must expose Connect"
        )
        XCTAssertTrue(app.buttons["edit-Menu-Me"].exists, "context menu must expose Edit")
        XCTAssertTrue(app.buttons["duplicate-Menu-Me"].exists, "context menu must expose Duplicate")
        XCTAssertTrue(app.buttons["forget-host-Menu-Me"].exists, "context menu must expose Forget Host")
        XCTAssertTrue(app.buttons["delete-Menu-Me"].exists, "context menu must expose Delete")

        // The context menu is still scaling in when its items enter the AX
        // hierarchy; gate the tap on the item being tappable.
        awaitHittable(app.buttons["edit-Menu-Me"])
        app.buttons["edit-Menu-Me"].tap()
        let nameField = app.textFields["field-name"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 5),
            "context-menu Edit must open the connection editor"
        )
        XCTAssertEqual(nameField.value as? String, "Menu Me")
        awaitConnectionEditorInteractive()
        app.buttons["cancel-editor"].tap()

        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row must survive the menu round-trip")
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
        awaitHittable(unavailableChoice)
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

        openHopEditor()
        let hostField = app.textFields["hop-field-host"]
        typeInto(hostField, "hop.example.com")

        app.buttons["cancel-hop"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5),
            "cancelling a dirty hop draft must prompt"
        )
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()

        // The old gate waited only for the hop editor's host field to leave
        // the AX hierarchy — that fires at pop START, while the dialog
        // dismissal and pop transition are still unwinding, so the scroll
        // below raced them (same family as the rerun8 line-704 failure).
        awaitHopDiscardPopCompleted()
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
        // The dialog is still animating in when its buttons enter the AX
        // hierarchy; a tap synthesized mid-presentation is swallowed and the
        // action silently never fires.
        awaitHittable(button)
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

        openHopEditor()

        let hostField = app.textFields["hop-field-host"]
        XCTAssertFalse(app.staticTexts["hop-field-host-error"].exists,
                       "a pristine blank hop must not flag the host field")
        XCTAssertFalse(app.staticTexts["hop-field-username-error"].exists,
                       "a pristine blank hop must not flag the username field")

        typeInto(hostField, "bad_host")
        XCTAssertTrue(app.staticTexts["hop-field-host-error"].waitForExistence(timeout: 5),
                      "editing a hop field must arm its inline error")

        app.buttons["cancel-hop"].tap()
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
        // The discard fires two stacked transitions — the dialog dismissal
        // and the hop-editor pop — and the scroll below must not race them:
        // a swipe-down issued mid-pop falls through the interaction-disabled
        // transitioning content onto the sheet's platter, where the sheet's
        // pan recognizer reads it as a drag-to-dismiss. With a clean parent
        // draft that dismissal is permitted, so the editor sheet closes and
        // field-name never returns (rerun8 line-704 failure).
        awaitHopDiscardPopCompleted()
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
        openKeyPicker()
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
        openKeyPicker()
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
        // The .password content type can surface the system save prompt
        // when field editing ends (swallowing the save tap) and again
        // when the editor sheet dismisses over the list.
        app.dismissSystemSavePromptIfPresent()
        savePasswordFixture()
        app.dismissSystemSavePromptIfPresent()
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
        let duplicate = app.buttons["duplicate-Credential-Fixture"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        awaitHittable(duplicate)
        duplicate.tap()
        XCTAssertTrue(app.buttons["save-editor"].waitForExistence(timeout: 5))
        awaitConnectionEditorInteractive()
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
        // The .password content type can surface the system save prompt
        // when field editing ends (swallowing the save tap) and again
        // when the editor sheet dismisses over the list.
        app.dismissSystemSavePromptIfPresent()
        XCTAssertFalse(app.staticTexts["password-removal-status"].exists)
        XCTAssertTrue(app.staticTexts["password-field-status"].label.contains("Will be saved"))
        savePasswordFixture()
        app.dismissSystemSavePromptIfPresent()
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
        openKeyPicker()
        app.buttons["key-Fixture-Ed25519"].tap()
        app.buttons["customize-done"].tap()
        XCTAssertFalse(warning.exists)
    }

    // MARK: Hop-row pool summaries

    func testHopSummariesReflectPoolModel() {
        app.launchArguments = ["-uitest-reset-keys", "--uitest-reset", "-uitest-biometrics-bypass"]
        app.launch()
        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Hop Summaries")
        typeInto(app.textFields["field-host"], "10.0.0.9")
        typeInto(app.textFields["field-username"], "alice")

        // Default hop: inherits the enabled pool (the three fixture keys).
        addHop(host: "127.0.0.1", port: "12222", username: "hop1user")
        assertHopCredential(0, equals: "hop1user · All keys (3 offered)")

        // Keys-off hop falls back to the password summary.
        editHop(0)
        XCTAssertTrue(setToggle(app.switches["hop-offer-keys-toggle"], on: false))
        saveHop()
        assertHopCredential(0, equals: "hop1user · Password")

        // Custom hop: two explicitly selected keys.
        editHop(0)
        XCTAssertTrue(setToggle(app.switches["hop-offer-keys-toggle"], on: true))
        openHopKeyPicker()
        let hop2Row = app.buttons["key-Fixture-Hop2-Unauthorized"]
        XCTAssertTrue(hop2Row.waitForExistence(timeout: 5))
        hop2Row.tap()
        app.buttons["customize-done"].tap()
        saveHop()
        assertHopCredential(0, equals: "hop1user · 2 selected keys")

        let saveEditor = app.buttons["save-editor"]
        scrollToHittable(saveEditor)
        XCTAssertTrue(saveEditor.isEnabled)
        saveEditor.tap()
        XCTAssertTrue(app.buttons["connection-Hop-Summaries"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["auth-method-Hop-Summaries"].label, "All keys (3 offered)",
                      "the row badge mirrors the destination's inherited pool, not the hop's selection")

        // Disabling one of the two custom keys in Key Management must
        // recompute both the list row and the hop row without a relaunch.
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let sshKeys = app.buttons["settings-ssh-keys"]
        scrollToHittable(sshKeys)
        XCTAssertTrue(sshKeys.waitForExistence(timeout: 5))
        sshKeys.tap()
        let fixtureToggle = app.switches["Enable Fixture Ed25519"]
        XCTAssertTrue(fixtureToggle.waitForExistence(timeout: 5))
        fixtureToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(
            for: NSPredicate(format: "value == 'Disabled'"),
            evaluatedWith: app.buttons["key-row-Fixture Ed25519"]
        )
        waitForExpectations(timeout: 5)
        app.buttons["keys-done"].tap()
        app.navigationBars["Settings"].buttons.firstMatch.tap()

        XCTAssertEqual(app.staticTexts["auth-method-Hop-Summaries"].label, "All keys (2 offered)",
                      "the list row must update live after the key toggle (3 → 2 enabled)")
        openEditorForConnection(named: "Hop-Summaries")
        assertHopCredential(0, equals: "hop1user · 1 selected keys")

        // Freshness: generating a key while the editor is open grows the
        // enabled pool (2 → 3); returning the hop to inherited must show
        // the NEW count, not a snapshot from editor-open time.
        editHop(0)
        openHopKeyPicker()
        app.buttons["picker-add-menu"].tap()
        let generateItem = app.buttons["picker-menu-generate"].exists
            ? app.buttons["picker-menu-generate"]
            : app.buttons["Generate Key"]
        XCTAssertTrue(generateItem.waitForExistence(timeout: 5))
        awaitHittable(generateItem)
        generateItem.tap()
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        awaitHittable(labelField)
        typeInto(labelField, "Fresh Hop Key")
        XCTAssertTrue(setToggle(app.switches["generate-biometrics"], on: false))
        app.buttons["generate-save"].tap()
        // The generate sheet dismisses, auto-selects the new key, and pops
        // the picker back onto the hop editor; gate on both layers being
        // gone before interacting with the hop editor again.
        let sheetDismissed = NSPredicate(format: "exists == false")
        expectation(for: sheetDismissed, evaluatedWith: app.textFields["generate-label"])
        waitForExpectations(timeout: 10)
        let selectorReady = NSPredicate(format: "hittable == true")
        expectation(for: selectorReady, evaluatedWith: app.buttons["hop-key-selector"])
        waitForExpectations(timeout: 10)
        openHopKeyPicker()
        app.buttons["use-all-enabled-keys"].tap()
        app.buttons["customize-done"].tap()
        saveHop()
        assertHopCredential(0, equals: "hop1user · All keys (3 offered)")
    }

    private func openHopKeyPicker() {
        let selector = app.buttons["hop-key-selector"]
        scrollToHittable(selector)
        selector.tap()
        XCTAssertTrue(app.buttons["use-all-enabled-keys"].waitForExistence(timeout: 5),
                      "hop key picker did not open")
        // The picker push must finish before any key row is tapped.
        awaitHittable(app.buttons["customize-done"])
    }

    private func editHop(_ index: Int) {
        let edit = app.buttons["edit-hop-\(index)"]
        scrollToHittable(edit)
        edit.tap()
        // The push must finish before the hop editor can receive taps:
        // mid-slide the destination's controls sit off-window and a tap
        // synthesized at a stale frame is swallowed. Gate on the editor's
        // own toolbar being interactive (same pattern as saveHop).
        awaitHopEditorPushed()
    }

    private func saveHop() {
        let save = app.buttons["save-hop"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        awaitHopEditorInteractive()
        save.tap()
        let popped = NSPredicate(format: "exists == false")
        expectation(for: popped, evaluatedWith: app.textFields["hop-field-host"])
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

    /// "The hop editor can receive a tap": any pushed key picker has
    /// finished popping back (its toolbar left the hierarchy) and the hop
    /// editor's own Save is hittable again. Both predicates hold instantly
    /// when no picker transition is in flight, so it is safe to gate every
    /// save-hop tap, not just the ones that follow customize-done.
    private func awaitHopEditorInteractive() {
        let pickerGone = NSPredicate(format: "exists == false")
        expectation(for: pickerGone, evaluatedWith: app.buttons["customize-done"])
        waitForExpectations(timeout: 10)
        let saveReady = NSPredicate(format: "hittable == true")
        expectation(for: saveReady, evaluatedWith: app.buttons["save-hop"])
        waitForExpectations(timeout: 10)
    }

    /// `hittable` is the "incoming chrome can receive the synthesized tap"
    /// signal: existence fires at a transition's START (SwiftUI puts views
    /// into the AX hierarchy while the animation is still running, with user
    /// interaction disabled on the transitioning content), while hittable
    /// only holds once the element is on-screen and uncovered. Passes
    /// instantly for an already-at-rest view, so callers can gate every
    /// entry unconditionally.
    private func awaitHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    /// The connection editor sheet can receive taps: any pushed key picker
    /// has finished popping back (`customize-done` left the hierarchy) and
    /// the editor's own Cancel is hittable. Both predicates hold instantly
    /// when no transition is in flight, so every editor entry point can gate
    /// on it. The settle covers the UIKit transition-snapshot window no
    /// AX-visible predicate can see — hittable can fire mid-transition
    /// (dfa04fb) — and a tap or swipe issued in that window lands on the
    /// sliding views and is swallowed (or, on a sheet with a clean draft,
    /// falls through to the platter and reads as a drag-to-dismiss).
    private func awaitConnectionEditorInteractive() {
        let pickerGone = NSPredicate(format: "exists == false")
        expectation(for: pickerGone, evaluatedWith: app.buttons["customize-done"])
        waitForExpectations(timeout: 10)
        awaitHittable(app.buttons["cancel-editor"])
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// The hop editor push has finished: the pushed form exists and its own
    /// toolbar is interactive. Same mid-transition caveat as
    /// awaitConnectionEditorInteractive; this gate plus typeInto's focus
    /// gate are the dfa04fb editHop pattern, proven across certification
    /// runs.
    private func awaitHopEditorPushed() {
        XCTAssertTrue(app.textFields["hop-field-host"].waitForExistence(timeout: 10))
        awaitHittable(app.buttons["cancel-hop"])
    }

    /// Scrolls to and taps add-hop, then gates on the hop editor being
    /// interactive before any field is touched.
    private func openHopEditor() {
        let addHopButton = app.buttons["add-hop"]
        scrollToHittable(addHopButton)
        addHopButton.tap()
        awaitHopEditorPushed()
    }

    /// Opens the connection editor's key picker and gates on its toolbar
    /// being interactive before any row is tapped.
    private func openKeyPicker() {
        dismissKeyboard()
        let selector = app.buttons["key-selector"]
        scrollToHittable(selector)
        selector.tap()
        awaitHittable(app.buttons["customize-done"])
    }

    /// Discarding a hop dismisses the confirmation dialog AND pops the hop
    /// editor — two stacked transitions. Gate on the outgoing hop chrome
    /// leaving the hierarchy (fires at pop start) and the connection editor
    /// being interactive again (fires once the pop completes) before any
    /// further tap or scroll. A swipe issued mid-pop falls through the
    /// interaction-disabled transitioning content onto the sheet's platter,
    /// where the sheet's pan recognizer reads it as a drag-to-dismiss; with
    /// a clean parent draft that dismissal is permitted and the editor
    /// closes outright, so the connection form never returns (rerun8
    /// line-704 failure).
    private func awaitHopDiscardPopCompleted() {
        let hopGone = NSPredicate(format: "exists == false")
        expectation(for: hopGone, evaluatedWith: app.buttons["cancel-hop"])
        waitForExpectations(timeout: 10)
        awaitConnectionEditorInteractive()
    }

    private func assertHopCredential(_ index: Int, equals expected: String) {
        let credential = app.staticTexts["hop-\(index)-credential"]
        // The row sits just above the fold right after saving a hop, but
        // far below it when the editor reopens — reveal from both sides.
        // The downward pass is gated on the row being realized ABOVE the
        // window: a blind swipe-down on a freshly reopened editor sheet
        // whose form is still at its scroll origin triggers the sheet's
        // drag-to-dismiss and closes the editor (2026-09-20 rerun4 flake),
        // and a row far below the fold is not realized at all, so the
        // downward pass could never reveal it anyway.
        if credential.exists, credential.frame.minY < app.windows.firstMatch.frame.minY {
            scrollToHittable(credential, swipingUp: false)
        }
        scrollToHittable(credential)
        XCTAssertEqual(credential.label, expected)
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
        // The row may sit under an editor sheet that is still dismissing
        // (or under a just-dismissed confirmation dialog); a tap on the
        // covered row is swallowed.
        awaitHittable(row)
        row.tap()
        if app.buttons["trust-confirm"].waitForExistence(timeout: 3) {
            awaitHittable(app.buttons["trust-confirm"])
            app.buttons["trust-confirm"].tap()
        }
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
        // The add button may still be covered by a dismissing key-management
        // cover or Settings scene; a tap on the covered button is swallowed.
        awaitHittable(add)
        add.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
        awaitConnectionEditorInteractive()
    }

    private func openEditorForConnection(named identifier: String) {
        swipeRow(named: identifier)
        let edit = app.buttons["edit-\(identifier)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        // The swipe actions are still sliding in when they enter the AX
        // hierarchy; a tap synthesized mid-reveal lands on the row instead.
        awaitHittable(edit)
        edit.tap()
        XCTAssertTrue(app.buttons["cancel-editor"].waitForExistence(timeout: 10))
        awaitConnectionEditorInteractive()
    }

    /// Types `text` into `field`. A replacement (`clearing`) is only done
    /// once the field verifiably shows the typed text: under simulator load
    /// the edit menu often never appears within its wait, the clear is
    /// silently skipped, and the typed text appends to the old value — the
    /// corrupted port then disables `save-hop` (its tap becomes a no-op and
    /// the `exists == 0` wait for the hop editor times out) and a corrupted
    /// host suppresses the cycle warning. Retry the whole sequence instead
    /// of letting the corruption leak into later assertions.
    private func typeInto(_ field: XCUIElement, _ text: String, clearing existing: String? = nil) {
        for _ in 1...3 {
            field.tap()
            awaitKeyboardFocus(on: field)
            if existing != nil {
                selectAllForReplacement(of: field)
            }
            app.typeText(text)
            if existing == nil || fieldShowsValue(field, text) {
                dismissKeyboard()
                return
            }
        }
        dismissKeyboard()
        XCTFail("typing '\(text)' never replaced the field value; last read: \(field.value as? String ?? "nil")")
    }

    /// The AX value can lag the keystrokes by a snapshot; poll briefly.
    private func fieldShowsValue(_ field: XCUIElement, _ text: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == text { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (field.value as? String) == text
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
    /// When the menu never appears (common under simulator load) this
    /// returns WITHOUT clearing — the caller's value verification catches
    /// the resulting corruption and retries.
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
        performKeyboardDismiss()
        // Dismissal is animated: until the keyboard leaves the hierarchy the
        // form is still relayouting, and taps, scrolls, and isHittable checks
        // issued in that window race the relayout (observed: cycle-warning
        // isHittable flapped right after typing). Gate on the keyboard being
        // really gone before handing control back.
        let deadline = Date().addingTimeInterval(3)
        while app.keyboards.count > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func performKeyboardDismiss() {
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
        openKeyPicker()
        selectOnlyKey(label)
        app.buttons["customize-done"].tap()
        // customize-done pops the picker back onto the editor; gate the pop
        // before the caller's next tap or scroll (save-editor taps have
        // raced this pop's tail).
        awaitConnectionEditorInteractive()
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

    private func addHop(host: String, port: String, username: String) {
        let addHopButton = app.buttons["add-hop"]
        scrollToHittable(addHopButton)
        addHopButton.tap()
        awaitHopEditorPushed()

        typeInto(app.textFields["hop-field-host"], host)
        typeInto(app.textFields["hop-field-port"], port, clearing: "22")
        typeInto(app.textFields["hop-field-username"], username)
        saveHop()
    }

    private func addHop(host: String, port: String?, username: String, key: String) {
        let addHopButton = app.buttons["add-hop"]
        scrollToHittable(addHopButton)
        addHopButton.tap()
        awaitHopEditorPushed()

        typeInto(app.textFields["hop-field-host"], host)
        if let port {
            let portField = app.textFields["hop-field-port"]
            typeInto(portField, port, clearing: "22")
        }
        typeInto(app.textFields["hop-field-username"], username)

        app.buttons["hop-key-selector"].tap()
        awaitHittable(app.buttons["customize-done"])
        let keyButton = app.buttons["key-\(key.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(keyButton.waitForExistence(timeout: 5))
        selectOnlyKey(key)
        app.buttons["customize-done"].tap()

        // customize-done pops the picker back onto the hop editor; saveHop
        // gates on that pop finishing before it taps save-hop.
        saveHop()
    }

    private func swipeRow(named identifier: String) {
        // A swipe issued while an editor sheet is still dismissing falls on
        // the transition remnant and is swallowed; the list's own chrome is
        // only hittable once the sheet is fully gone. Passes instantly when
        // the list is already at rest.
        awaitHittable(app.buttons["add-connection"])
        let row = app.buttons["connection-\(identifier)"]
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            row.swipeLeft()
        }
    }
}
