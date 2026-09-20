import XCTest

/// T5 herdr connection option UI tests: the editor's Herdr section (toggle,
/// conditional remote-session field, consequence footer), the list's Herdr
/// capsule badge, and persistence across relaunch. Editor-only flows — no
/// fixtures required.
@MainActor
final class HerdrConnectionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testHerdrToggleSessionFieldAndBadgePersistAcrossRelaunch() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Herdr Edit")
        typeInto(app.textFields["field-host"], "10.4.5.6")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "SSH connections offer the Herdr section")
        XCTAssertFalse(
            app.textFields["herdr-session-field"].exists,
            "the remote-session field stays hidden while herdr is off"
        )

        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")

        let sessionField = app.textFields["herdr-session-field"]
        XCTAssertTrue(sessionField.waitForExistence(timeout: 5), "enabling herdr reveals the session field")
        typeInto(sessionField, "work")

        let footer = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "herdr-section-footer")
        ).firstMatch
        scrollTo(footer)
        XCTAssertTrue(
            footer.label.contains("herdr 0.9"),
            "the footer states the server requirement: \(footer.label)"
        )
        XCTAssertTrue(
            footer.label.contains("workspace"),
            "the footer states the consequence of enabling herdr: \(footer.label)"
        )

        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Herdr-Edit"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["badge-herdr"].waitForExistence(timeout: 5),
            "a herdr-enabled connection carries the Herdr capsule"
        )
        attachScreenshot("herdr-badge-in-list")

        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(
            app.buttons["connection-Herdr-Edit"].waitForExistence(timeout: 10),
            "the connection must survive relaunch"
        )
        XCTAssertTrue(
            app.staticTexts["badge-herdr"].waitForExistence(timeout: 5),
            "the herdr badge must survive relaunch"
        )

        openEditorForConnection(named: "Herdr-Edit")
        let relaunchedToggle = app.switches["herdr-toggle"]
        scrollTo(relaunchedToggle)
        XCTAssertTrue(relaunchedToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(
            (relaunchedToggle.value as? String ?? "").lowercased(), "1",
            "the herdr toggle must persist across relaunch"
        )
        let relaunchedSession = app.textFields["herdr-session-field"]
        XCTAssertTrue(relaunchedSession.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunchedSession.value as? String, "work", "the session name must persist")

        XCTAssertTrue(
            setToggle(relaunchedToggle, on: false),
            "the herdr toggle must flip off after relaunch"
        )
        XCTAssertTrue(
            app.textFields["herdr-session-field"].waitForNonExistence(timeout: 10),
            "disabling herdr hides the session field"
        )
        app.buttons["save-editor"].tap()

        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["badge-herdr"].exists,
            "the badge disappears once herdr is disabled"
        )
        XCTAssertTrue(app.buttons["connection-Herdr-Edit"].exists, "the connection itself is kept")
    }

    func testInvalidSessionNameBlocksSave() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Bad Session")
        typeInto(app.textFields["field-host"], "10.4.5.7")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")
        typeInto(app.textFields["herdr-session-field"], "bad session!")

        scrollTo(app.buttons["save-editor"])
        XCTAssertFalse(
            app.buttons["save-editor"].isEnabled,
            "an invalid remote session name must block saving"
        )
        app.buttons["cancel-editor"].tap()
    }

    /// Rebase seam: password auth and the Herdr section coexist in one
    /// editor — one save flow exercising both. Pool model: password auth
    /// means keys stay out of the offer and a password is saved, the row
    /// summarizes it as "Password", and the editor reopens with the
    /// "Saved on this device" badge.
    func testPasswordAuthAndHerdrSessionSaveTogether() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Pwd Herdr")
        typeInto(app.textFields["field-host"], "10.4.5.8")
        typeInto(app.textFields["field-username"], "alice")
        dismissKeyboard()

        // Pool model: password auth = leave keys out of the offer and
        // save a password (blank would mean prompt-at-connect instead).
        let offerKeys = app.switches["offer-keys-toggle"]
        scrollTo(offerKeys)
        XCTAssertTrue(setToggle(offerKeys, on: false), "keys must stay out of the offer")
        typeIntoSecure(app.secureTextFields["password-field"], "bicterm-uitest-fixture-password")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")
        let sessionField = app.textFields["herdr-session-field"]
        XCTAssertTrue(sessionField.waitForExistence(timeout: 5), "enabling herdr reveals the session field")
        typeInto(sessionField, "work")

        scrollTo(app.buttons["save-editor"])
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        dismissSystemSavePromptIfPresent()

        let row = app.buttons["connection-Pwd-Herdr"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the combined connection must save")
        XCTAssertEqual(
            app.staticTexts["auth-method-Pwd-Herdr"].label, "Password",
            "the row summarizes the keys-off connection as password auth"
        )
        XCTAssertTrue(
            app.staticTexts["badge-herdr"].waitForExistence(timeout: 5),
            "the same connection carries the Herdr badge"
        )

        // Both halves persist together: the saved password surfaces as
        // the "Saved on this device" badge (never prefilled text) and
        // the herdr section reopens enabled with its session name.
        openEditorForConnection(named: "Pwd-Herdr")
        let secure = app.secureTextFields["password-field"]
        scrollTo(secure)
        XCTAssertTrue(
            app.staticTexts["password-saved-badge"].waitForExistence(timeout: 5),
            "the saved password must surface as the device badge"
        )
        let value = secure.value as? String
        XCTAssertTrue(
            value == nil || value == "",
            "SecureField must never be pre-filled from the store; got \(value ?? "<nil>")"
        )
        let relaunchedToggle = app.switches["herdr-toggle"]
        scrollTo(relaunchedToggle)
        XCTAssertEqual(
            (relaunchedToggle.value as? String ?? "").lowercased(), "1",
            "the herdr toggle must persist"
        )
        let relaunchedSession = app.textFields["herdr-session-field"]
        XCTAssertTrue(relaunchedSession.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunchedSession.value as? String, "work", "the session name must persist")
        app.buttons["cancel-editor"].tap()
    }

    /// Startup command (sent as terminal input when the shell comes up):
    /// visible only while herdr is off, preserved — hidden, not deleted —
    /// while herdr is on, and persisted across save + reopen.
    func testStartupCommandFieldVisibilityAndPersistence() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Startup Cmd")
        typeInto(app.textFields["field-host"], "10.4.5.9")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "SSH connections offer the Herdr section")

        let startupField = app.textFields["startup-command-field"]
        XCTAssertTrue(
            startupField.waitForExistence(timeout: 5),
            "herdr off: the startup-command field is visible"
        )
        typeInto(startupField, "tmux new-session -A -s main")

        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")
        XCTAssertTrue(
            app.textFields["startup-command-field"].waitForNonExistence(timeout: 10),
            "enabling herdr hides the startup-command field"
        )

        XCTAssertTrue(setToggle(toggle, on: false), "the herdr toggle must flip back off")
        let restoredField = app.textFields["startup-command-field"]
        XCTAssertTrue(
            restoredField.waitForExistence(timeout: 5),
            "disabling herdr reveals the field again"
        )
        XCTAssertEqual(
            restoredField.value as? String,
            "tmux new-session -A -s main",
            "the value is preserved, not deleted, while herdr was on"
        )

        scrollTo(app.buttons["save-editor"])
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Startup-Cmd"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the connection must save")

        openEditorForConnection(named: "Startup-Cmd")
        let reopenedField = app.textFields["startup-command-field"]
        scrollTo(reopenedField)
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 5))
        XCTAssertEqual(
            reopenedField.value as? String,
            "tmux new-session -A -s main",
            "the startup command must persist across save + reopen"
        )
        app.buttons["cancel-editor"].tap()
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

    /// Tap toward the trailing edge: on regular-width sheets SwiftUI can
    /// report the whole row as the SecureField's frame, and a center tap
    /// then lands between the label and the text box, never focusing the
    /// editor. 75% width is inside the text box in both AX shapes.
    private func typeIntoSecure(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(text)
        let bullets = field.value as? String
        XCTAssertEqual(bullets?.count, text.count, "secure input must land exactly")
        dismissKeyboard()
    }

    /// Binding updates land one render tick late on relaxed-timing hosts
    /// (observed: iPad simulator with hardware keyboard); poll instead of
    /// reading `isEnabled` synchronously.
    private func waitForEnabled(_ button: XCUIElement, timeout: TimeInterval = 8) {
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: timeout)
    }

    /// The editor opts out of the system password-vault flow via
    /// `.textContentType(.oneTimeCode)`, but iOS 26.5's AutoFill still
    /// presents its "Save Password?" sheet once the simulator's password
    /// subsystem is active — dismiss it so the flow under test continues.
    ///
    /// The alert's AX tree exposes "Not Now" before the alert accepts
    /// touches, so a tap synthesized in that window is silently swallowed
    /// (observed on iPhone: solo and full-suite runs). Verify the dismissal
    /// outcome and re-tap instead of trusting the first tap.
    private func dismissSystemSavePromptIfPresent() {
        let notNow = app.buttons["Not Now"]
        guard notNow.waitForExistence(timeout: 3) else { return }
        let dismissed = NSPredicate(format: "exists == false")
        for _ in 0..<4 {
            notNow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: dismissed, object: notNow)],
                timeout: 2
            ) == .completed {
                return
            }
        }
        XCTFail("the system Save Password alert did not dismiss after repeated Not Now taps")
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

    /// A SwiftUI Form Toggle's XCUI element spans the whole row; taps must
    /// land on the trailing edge where the switch renders.
    @discardableResult
    private func setToggle(_ element: XCUIElement, on: Bool) -> Bool {
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

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Manual removal poll: SwiftUI drops Form rows asynchronously (and the
    /// accessibility tree lags the animation), so the removal is re-queried
    /// fresh on every iteration rather than through one frozen expectation.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return !exists
    }
}
