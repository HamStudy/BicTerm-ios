import XCTest

/// T5 startup-command preset UI round-trip on the real app: pick the tmux
/// preset, save, reopen to the exact command; pick Shell, save, reopen to
/// empty; a changed preset still triggers the discard confirmation on
/// cancel. Editor-only flow — no fixtures required.
@MainActor
final class StartupPresetUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testStartupPresetRoundTripPersistsAndClears() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Preset Trip")
        typeInto(app.textFields["field-host"], "10.4.6.5")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        // Pick the tmux preset: the always-visible field is the source of
        // truth, so picking a preset must write the exact command into it.
        let presetPicker = app.buttons["startup-command-preset"]
        scrollTo(presetPicker)
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 5), "the preset picker row must exist")
        presetPicker.tap()
        let tmuxOption = app.buttons["tmux"]
        XCTAssertTrue(tmuxOption.waitForExistence(timeout: 5), "the preset menu must offer tmux")
        tmuxOption.tap()

        let field = app.textFields["startup-command-field"]
        scrollTo(field)
        XCTAssertTrue(
            waitForFieldValue(field, equals: "tmux new-session -A -s main"),
            "picking tmux must write the exact preset command into the field"
        )

        // The footer states the execution semantics verbatim.
        let footer = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "startup-section-footer")
        ).firstMatch
        scrollTo(footer)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the startup section footer must exist")
        XCTAssertEqual(
            footer.label,
            "Sent to the shell as input (with Return) after each connect and reconnect. The command must exist on the server — e.g. tmux attach restores your session automatically. Stored unencrypted — never put credentials here."
        )
        XCTAssertTrue(
            app.staticTexts["Applies to terminal sessions only"].exists,
            "the terminal-sessions footnote must render"
        )

        scrollTo(app.buttons["save-editor"])
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Preset-Trip"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the connection must save")

        // Reopen: the saved tmux value round-trips as the exact command.
        openEditorForConnection(named: "Preset-Trip")
        let reopened = app.textFields["startup-command-field"]
        scrollTo(reopened)
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(
            reopened.value as? String, "tmux new-session -A -s main",
            "the saved tmux preset must reopen as the exact command"
        )

        // Pick Shell: the field clears…
        let picker = app.buttons["startup-command-preset"]
        scrollTo(picker)
        picker.tap()
        let shellOption = app.buttons["Shell"]
        XCTAssertTrue(shellOption.waitForExistence(timeout: 5), "the preset menu must offer Shell")
        shellOption.tap()
        let cleared = app.textFields["startup-command-field"]
        XCTAssertTrue(
            waitForFieldValue(cleared, equals: ""),
            "picking Shell must clear the field"
        )

        scrollTo(app.buttons["save-editor"])
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Shell save must complete")

        // …and the clear persists across save + reopen.
        openEditorForConnection(named: "Preset-Trip")
        let emptyField = app.textFields["startup-command-field"]
        scrollTo(emptyField)
        XCTAssertTrue(emptyField.waitForExistence(timeout: 5))
        let reopenedValue = emptyField.value as? String ?? ""
        XCTAssertTrue(reopenedValue.isEmpty, "Shell must have cleared the stored command")

        // Editing then cancelling still prompts to discard.
        typeInto(emptyField, "echo hi")
        app.buttons["cancel-editor"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["discard-changes-dialog"].waitForExistence(timeout: 5),
            "cancelling a changed preset must trigger the discard confirmation"
        )
        dialogButton(identifier: "discard-confirm", label: "Discard Changes").tap()
    }

    // MARK: Helpers

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

    private func typeInto(_ field: XCUIElement, _ text: String) {
        field.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(text)
        dismissKeyboard()
    }

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        app.buttons["key-selector"].tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
        // The pool-model editor pushes KeyPickerView; selecting a key row
        // keeps the picker open, so Done must pop back to the editor.
        app.buttons["customize-done"].tap()
    }

    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let toolbarDone = app.toolbars.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        let plainDone = app.buttons["Done"]
        if plainDone.exists {
            plainDone.tap()
            return
        }
        for keyLabel in ["return", "done"] where app.keyboards.buttons[keyLabel].exists {
            app.keyboards.buttons[keyLabel].tap()
            return
        }
    }

    /// Binding updates land one render tick after the picker selection; poll
    /// instead of reading `value` synchronously.
    private func waitForFieldValue(_ field: XCUIElement, equals expected: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (field.value as? String) == expected
    }

    /// Binding updates land one render tick late on relaxed-timing hosts;
    /// poll instead of reading `isEnabled` synchronously.
    private func waitForEnabled(_ button: XCUIElement, timeout: TimeInterval = 8) {
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: timeout)
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

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }

    private func swipeRow(named identifier: String) {
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            app.buttons["connection-\(identifier)"].swipeLeft()
        }
    }
}
