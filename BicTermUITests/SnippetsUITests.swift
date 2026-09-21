import XCTest

/// t8 snippets on the REAL app surface. Launch A creates two global
/// snippets through Settings → Snippets (the management surface, with
/// `--uitest-reset` wiping any earlier snippet state). Launch B opens a
/// fixture SSH session (Alpha, hop1 12222) WITHOUT the reset so the
/// snippets survive, then drives the terminal scene's snippet sheet:
/// Run → Cancel sends zero bytes, Run → confirm executes the command
/// exactly once, and Insert emits the command text without executing
/// it. The probes use `tr A-Z a-z` so each command's EXECUTION output
/// (lowercase) is distinguishable from its echoed input (uppercase) in
/// the raw scene tail.
@MainActor
final class SnippetsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app.state != .notRunning {
            app.terminate()
        }
        super.tearDown()
    }

    private static let readyMarker = "__SNIPPETS_READY__"
    private static let insertCommand = "echo INSERT_PROBE_7734 | tr A-Z a-z"
    private static let runCommand = "echo RUN_PROBE_7734 | tr A-Z a-z"
    /// Only appears if the Insert probe's line is ever EXECUTED.
    private static let insertFired = "insert_probe_7734"
    /// Only appears when the Run probe's command executes.
    private static let runFired = "run_probe_7734"

    // MARK: - Launch A: management surface

    private func launchForManagement() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()
        XCTAssertTrue(
            app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 60),
            "connection list never appeared"
        )
    }

    private func createSnippet(name: String, command: String) {
        let add = app.buttons["snippet-add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Snippets add button missing")
        add.tap()

        let nameField = app.textFields["snippet-editor-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "snippet editor never appeared")
        nameField.tap()
        nameField.typeText(name)

        let commandField = app.textFields["snippet-editor-command"]
        commandField.tap()
        commandField.typeText(command)

        app.buttons["snippet-editor-save"].firstMatch.tap()

        let row = app.descendants(matching: .any)[
            "snippet-manage-row-\(name.replacingOccurrences(of: " ", with: "-"))"
        ].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "the saved snippet must appear in the management list"
        )
    }

    // MARK: - Launch B: fixture session

    private func launchFixtureSession() {
        app.launchArguments = [
            "--uitest-seed-keys", "--uitest-sessions", "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
            "--uitest-session-command", "printf __SNIPPETS_READY__\\\\n",
        ]
        app.launch()
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "session scene never appeared")
        let tail = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(
            waitFor(tail, contains: Self.readyMarker, timeout: 60),
            "fixture shell never became ready"
        )
    }

    private var tail: XCUIElement { app.staticTexts["scene-tail-Alpha"] }

    /// SwiftUI Texts report an EMPTY `value` to XCUI — content lives in
    /// `label`.
    private func label(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @discardableResult
    private func waitFor(
        _ element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("timed out waiting for \(element) to contain \(fragment.debugDescription); current: \(label(of: element).suffix(400).debugDescription)")
            return false
        }
        return true
    }

    /// Re-tapping the menu button closes an already-open menu, so the
    /// loop converges after failed attempts.
    @discardableResult
    private func openSnippetSheet() -> Bool {
        let menu = app.buttons["scene-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "session menu never appeared")
        menu.tap()
        let snippetsItem = app.buttons["scene-snippets"].firstMatch
        XCTAssertTrue(
            snippetsItem.waitForExistence(timeout: 10),
            "Snippets item missing from the session menu"
        )
        snippetsItem.tap()
        let sheet = app.descendants(matching: .any)["snippet-picker-sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "snippet sheet must present")
        return true
    }

    // MARK: - Test

    func testSnippetManagementInsertAndConfirmedRun() {
        // Launch A: create the two probes through Settings.
        launchForManagement()
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
            "Settings never appeared"
        )
        let snippetsRow = app.buttons["settings-snippets"].firstMatch
        XCTAssertTrue(snippetsRow.waitForExistence(timeout: 10), "Snippets row missing from Settings")
        snippetsRow.tap()
        XCTAssertTrue(
            app.buttons["snippet-add"].firstMatch.waitForExistence(timeout: 10),
            "Snippet management view never appeared"
        )
        createSnippet(name: "Insert Probe", command: Self.insertCommand)
        createSnippet(name: "Run Probe", command: Self.runCommand)
        app.terminate()

        // Launch B: fixture session with the snippets preserved.
        launchFixtureSession()

        // Run → Cancel: zero bytes.
        openSnippetSheet()
        XCTAssertTrue(
            app.descendants(matching: .any)["snippet-row-Run-Probe"].firstMatch
                .waitForExistence(timeout: 10),
            "the global Run Probe snippet must be listed"
        )
        app.buttons["snippet-run-Run-Probe"].firstMatch.tap()
        let confirmation = app.descendants(matching: .any)["snippet-run-confirmation"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), "Run must present the confirmation")
        XCTAssertTrue(
            label(of: app.descendants(matching: .any)["snippet-run-command"].firstMatch)
                .contains("RUN_PROBE_7734"),
            "the confirmation must show the exact command"
        )
        XCTAssertTrue(
            label(of: app.descendants(matching: .any)["snippet-run-target"].firstMatch)
                .contains("Alpha"),
            "the confirmation must show the target connection name"
        )
        app.buttons["snippet-run-cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["snippet-picker-sheet"].firstMatch
                .waitForExistence(timeout: 5),
            "cancel must return to the snippet list"
        )
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(
            label(of: tail).contains(Self.runFired),
            "cancel must send zero bytes (tail: \(label(of: tail).suffix(200)))"
        )

        // Run → confirm: executes exactly once.
        app.buttons["snippet-run-Run-Probe"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        app.buttons["snippet-run-confirm"].firstMatch.tap()
        XCTAssertTrue(
            waitFor(tail, contains: Self.runFired, timeout: 20),
            "a confirmed Run must execute the command"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["snippet-picker-sheet"].firstMatch
                .waitForExistence(timeout: 3),
            "a confirmed Run must dismiss the snippet sheet"
        )
        let occurrences = label(of: tail).components(separatedBy: Self.runFired).count - 1
        XCTAssertEqual(
            occurrences, 1,
            "the command must execute exactly once (tail: \(label(of: tail).suffix(400)))"
        )

        // Insert: emits the command without executing it.
        openSnippetSheet()
        app.buttons["snippet-insert-Insert-Probe"].firstMatch.tap()
        XCTAssertTrue(
            waitFor(tail, contains: "INSERT_PROBE_7734", timeout: 20),
            "Insert must emit the command bytes"
        )
        XCTAssertFalse(
            label(of: tail).contains(Self.insertFired),
            "Insert must not execute the command (tail: \(label(of: tail).suffix(200)))"
        )
    }
}
