import XCTest

/// T7 herd editor + list UI tests: creating a herd from existing SSH
/// connections, per-machine rows with optional remote sessions, persistence
/// across relaunch, orphan machines after their connection is deleted, and
/// the connection-delete confirmation's herd-reference warning. No fixtures
/// required — the seeded connections are never connected.
@MainActor
final class HerdsEditorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testCreateHerdAddMachinesAndPersistAcrossRelaunch() {
        app.launchArguments = ["--uitest-reset", "--uitest-herd-reset", "--uitest-seed-keys", "--uitest-sessions"]
        app.launch()

        XCTAssertTrue(
            app.buttons["connection-Alpha"].waitForExistence(timeout: 15),
            "the fixture connections must be seeded"
        )
        XCTAssertTrue(app.buttons["connection-Beta"].waitForExistence(timeout: 5))

        app.buttons["add-herd"].tap()
        XCTAssertTrue(app.textFields["field-herd-name"].waitForExistence(timeout: 10))
        typeInto(app.textFields["field-herd-name"], "Farm")

        addMachine("Alpha")
        addMachine("Beta")

        let alphaSession = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "herd-machine-session-")
        ).firstMatch
        scrollTo(alphaSession)
        typeInto(alphaSession, "alpha")

        scrollTo(app.buttons["save-herd"])
        app.buttons["save-herd"].tap()

        let herdRow = app.buttons["herd-Farm"]
        XCTAssertTrue(herdRow.waitForExistence(timeout: 10), "the saved herd must be listed")
        waitUntil(herdRow, contains: "2 machines")
        attachScreenshot("herds-list-row")

        app.terminate()
        app.launchArguments = ["--uitest-sessions"]
        app.launch()

        let relaunched = app.buttons["herd-Farm"]
        XCTAssertTrue(
            relaunched.waitForExistence(timeout: 15),
            "the herd must survive relaunch"
        )
        waitUntil(relaunched, contains: "2 machines")

        swipeHerdRow(named: "Farm")
        let edit = app.buttons["edit-herd-Farm"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let sessionField = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "herd-machine-session-")
        ).firstMatch
        XCTAssertTrue(sessionField.waitForExistence(timeout: 10), "the machine rows must persist")
        XCTAssertEqual(
            sessionField.value as? String, "alpha",
            "the machine's remote session name must persist"
        )
        let machineCells = app.cells.containing(.staticText, identifier: "herd-machine-name")
        XCTAssertTrue(
            machineCells.firstMatch.waitForExistence(timeout: 5),
            "machine rows keep their connection labels"
        )
        app.buttons["cancel-herd-editor"].tap()
    }

    func testOrphanMachineShowsMissingBadgeAfterConnectionDelete() {
        app.launchArguments = ["--uitest-reset", "--uitest-herd-reset", "--uitest-seed-keys", "--uitest-sessions"]
        app.launch()

        XCTAssertTrue(app.buttons["connection-Alpha"].waitForExistence(timeout: 15))
        createHerd(named: "Orphan Farm", machines: ["Alpha"])

        swipeConnectionRow(named: "Alpha")
        let delete = app.buttons["delete-Alpha"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        let confirm = app.buttons["confirm-delete-connection"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "deleting a connection must ask for confirmation"
        )
        confirm.tap()
        XCTAssertFalse(
            app.buttons["connection-Alpha"].waitForExistence(timeout: 10),
            "the connection must be deleted"
        )

        let herdRow = app.buttons["herd-Orphan-Farm"]
        XCTAssertTrue(herdRow.waitForExistence(timeout: 10))
        waitUntil(
            herdRow,
            contains: "1 connection is missing",
            message: "the herd row summarizes the orphaned machine"
        )

        swipeHerdRow(named: "Orphan-Farm")
        app.buttons["edit-herd-Orphan-Farm"].tap()
        XCTAssertTrue(
            app.staticTexts["herd-machine-missing"].waitForExistence(timeout: 10),
            "the orphaned machine row shows the Missing connection badge"
        )
        attachScreenshot("herd-orphan-machine")

        let orphanCell = app.cells.containing(.staticText, identifier: "herd-machine-missing").firstMatch
        orphanCell.swipeLeft()
        let remove = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "remove-herd-machine-")
        ).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(
            app.staticTexts["herd-machine-missing"].waitForNonExistence(timeout: 10),
            "the orphaned machine row is gone after Remove"
        )

        scrollTo(app.buttons["save-herd"])
        app.buttons["save-herd"].tap()
        let updatedRow = app.buttons["herd-Orphan-Farm"]
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 10))
        waitUntil(updatedRow, contains: "0 machines")
    }

    func testConnectionDeleteConfirmationNamesReferencingHerds() {
        app.launchArguments = ["--uitest-reset", "--uitest-herd-reset", "--uitest-seed-keys", "--uitest-sessions"]
        app.launch()

        XCTAssertTrue(app.buttons["connection-Alpha"].waitForExistence(timeout: 15))
        createHerd(named: "Referencing Farm", machines: ["Alpha"])

        swipeConnectionRow(named: "Alpha")
        app.buttons["delete-Alpha"].tap()

        let message = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Also used by herd(s)")
        ).firstMatch
        XCTAssertTrue(
            message.waitForExistence(timeout: 10),
            "the delete confirmation must warn about herd references"
        )
        waitUntil(message, contains: "Referencing Farm")
        attachScreenshot("herd-delete-warning")

        app.buttons["confirm-delete-connection"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["herd-Referencing-Farm"].waitForExistence(timeout: 10),
            "the herd itself survives the connection delete"
        )
    }

    // MARK: Helpers

    private func createHerd(named name: String, machines: [String]) {
        app.buttons["add-herd"].tap()
        XCTAssertTrue(app.textFields["field-herd-name"].waitForExistence(timeout: 10))
        typeInto(app.textFields["field-herd-name"], name)
        for machine in machines {
            addMachine(machine)
        }
        scrollTo(app.buttons["save-herd"])
        app.buttons["save-herd"].tap()
        XCTAssertTrue(app.buttons["herd-\(name.replacingOccurrences(of: " ", with: "-"))"].waitForExistence(timeout: 10))
    }

    private func addMachine(_ name: String) {
        scrollTo(app.buttons["add-herd-machine"])
        app.buttons["add-herd-machine"].tap()
        let candidate = app.buttons["herd-candidate-\(name)"]
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 10),
            "connection \(name) must be offered as a machine candidate"
        )
        candidate.tap()
        XCTAssertTrue(
            app.cells.containing(.staticText, identifier: "herd-machine-name").firstMatch
                .waitForExistence(timeout: 10),
            "the picked connection becomes a machine row"
        )
    }

    private func typeInto(_ field: XCUIElement, _ text: String) {
        field.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(text)
        dismissKeyboard()
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

    @discardableResult
    private func waitUntil(
        _ element: XCUIElement,
        contains needle: String,
        timeout: TimeInterval = 15,
        message: String = ""
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", needle),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        XCTAssertTrue(result, "\(message) — expected '\(needle)' in: \(element.label)")
        return result
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }

    private func swipeConnectionRow(named identifier: String) {
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            app.buttons["connection-\(identifier)"].swipeLeft()
        }
    }

    private func swipeHerdRow(named identifier: String) {
        let cell = app.cells.containing(.button, identifier: "herd-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            app.buttons["herd-\(identifier)"].swipeLeft()
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
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return !exists
    }
}
