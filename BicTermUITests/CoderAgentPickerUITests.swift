import XCTest

/// T11 UI coverage: agent picker on multi-agent workspaces, start-stopped
/// policy (OFF refuses to start; ON starts exactly once and connects after
/// readiness), dormancy/parameter-mismatch action-required screens, and the
/// Coder session info diagnostics row.
@MainActor
final class CoderAgentPickerUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Helpers (mirrors CoderServersUITests patterns)

    private func launchReset(extra flags: [String] = []) {
        app.launchArguments = [
            "-uitest-reset-configuration",
            "--uitest-reset",
            "--uitest-coder-fake-validation",
            "--uitest-coder-workspaces",
            "--uitest-reset-keys",
            "--uitest-seed-keys",
            "--uitest-force-connection-list",
        ] + flags
        app.launch()
    }

    private func relaunch(flags: [String]) {
        app.terminate()
        app.launchArguments = [
            "--uitest-coder-fake-validation",
            "--uitest-coder-workspaces",
            "--uitest-force-connection-list",
        ] + flags
        app.launch()
    }

    private func addFixtureServer(name: String) {
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-coder-servers"].waitForExistence(timeout: 5))
        app.buttons["settings-coder-servers"].tap()
        XCTAssertTrue(app.navigationBars["Coder Servers"].waitForExistence(timeout: 5))

        app.buttons["add-coder-server"].tap()
        XCTAssertTrue(app.navigationBars["Add Coder Server"].waitForExistence(timeout: 5))
        enterText(name, in: app.textFields["coder-server-name"])
        enterText("https://coder.example.com", in: app.textFields["coder-server-url"])
        enterText("any-token", in: app.secureTextFields["coder-server-token"])
        app.buttons["coder-server-validate-save"].tap()
        XCTAssertTrue(app.buttons["coder-server-\(name.replacingOccurrences(of: " ", with: "-"))"].waitForExistence(timeout: 10))

        let coderBack = app.navigationBars["Coder Servers"].buttons.element(boundBy: 0)
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

    private func createCoderConnection(
        name: String,
        multiAgent: Bool = false,
        startPolicy: Bool = false
    ) {
        openNewConnectionEditor()
        enterText(name, in: app.textFields["field-name"])
        selectCoderProtocol()
        enterText("coder.example.com", in: app.textFields["field-host"])
        enterText("user", in: app.textFields["field-username"])

        dismissKeyboard()
        let serverPicker = app.buttons["coder-server-picker"]
        scrollToHittable(serverPicker)
        serverPicker.tap()
        let serverChoice = app.buttons["Fixture Server"]
        XCTAssertTrue(serverChoice.waitForExistence(timeout: 5))
        serverChoice.tap()

        let runningWorkspace = app.buttons["coder-workspace-Running-Dev"]
        XCTAssertTrue(runningWorkspace.waitForExistence(timeout: 10))
        runningWorkspace.tap()

        if multiAgent {
            pickAgent("main")
        }
        if startPolicy {
            enableStartPolicy()
        }
        selectAuthenticationKey("Fixture Ed25519")

        let save = app.buttons["save-editor"]
        scrollToHittable(save)
        XCTAssertTrue(save.isEnabled, "connection must be savable (agent/policy/key resolved)")
        save.tap()
        let savedRow = waitForRow(named: name)
        XCTAssertTrue(savedRow.exists, "saved connection row must appear in the list")
    }

    /// The connection list is lazy: rows beyond the fold are absent from the
    /// accessibility tree, so discovery scrolls until the row materializes.
    private func waitForRow(named name: String, timeout: TimeInterval = 10) -> XCUIElement {
        let row = app.buttons["connection-\(rowID(name))"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !row.exists && Date() < deadline {
            app.swipeUp()
            usleep(300_000)
        }
        return row
    }

    private func rowID(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private func pickAgent(_ agentName: String) {
        dismissKeyboard()
        let agentRow = app.buttons["coder-agent-row"]
        scrollToHittable(agentRow)
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "multi-agent workspace must expose the agent picker")
        if agentRow.staticTexts.firstMatch.exists {
            agentRow.staticTexts.firstMatch.tap()
        } else {
            agentRow.tap()
        }

        let agent = app.buttons["coder-agent-\(agentName)"]
        if !agent.waitForExistence(timeout: 5) {
            print("===== PICKER FAILURE TREE =====")
            print(app.debugDescription)
            print("===== END PICKER TREE =====")
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 2), "agent \(agentName) must be listed in the picker")
        agent.tap()

        let dismissed = app.navigationBars["Select Agent"]
        XCTAssertFalse(dismissed.waitForExistence(timeout: 2), "picker sheet should dismiss after selection")
    }

    private func enableStartPolicy() {
        dismissKeyboard()
        let toggle = app.switches["coder-start-policy-toggle"]
        scrollToHittable(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.switches.firstMatch.exists {
            toggle.switches.firstMatch.tap()
        } else {
            toggle.tap()
        }

        let confirm = app.buttons["coder-start-policy-confirm"].firstMatch
        if !confirm.waitForExistence(timeout: 5) {
            print("===== DIALOG FAILURE TREE =====")
            print(app.debugDescription)
            print("===== END DIALOG TREE =====")
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 2), "turning the policy on must present the cost confirmation dialog")
        confirm.tap()
    }

    private func connect(_ name: String) {
        let row = waitForRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "connection row must exist before connecting")
        scrollToHittable(row)
        row.swipeLeft()
        let connect = app.buttons["connect-\(rowID(name))"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "swiping the row must reveal the Connect action")
        tap(connect)
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
        guard app.keyboards.firstMatch.exists else { return }
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
        app.swipeDown()
        let keySelector = app.buttons["key-selector"]
        scrollToHittable(keySelector)
        keySelector.tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
    }

    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 8) {
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

    private func terminalSurface() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminalView").firstMatch
    }

    private func startPostCount() -> Int {
        let label = app.staticTexts["coder-start-post-count"]
        XCTAssertTrue(label.waitForExistence(timeout: 5), "fixture start-post counter must be visible")
        let parts = label.label.split(separator: ":")
        guard let raw = parts.last,
              let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            XCTFail("unparseable start-post counter: \(label.label)")
            return -1
        }
        return value
    }

    // MARK: - Flow 1: agent picker on a two-agent workspace

    func testTwoAgentWorkspaceShowsPickerAndPersistsChoice() {
        launchReset(extra: ["--uitest-coder-multi-agent"])
        addFixtureServer(name: "Fixture Server")

        openNewConnectionEditor()
        enterText("Multi Agent", in: app.textFields["field-name"])
        selectCoderProtocol()
        enterText("coder.example.com", in: app.textFields["field-host"])
        enterText("user", in: app.textFields["field-username"])

        dismissKeyboard()
        let serverPicker = app.buttons["coder-server-picker"]
        scrollToHittable(serverPicker)
        serverPicker.tap()
        let serverChoice = app.buttons["Fixture Server"]
        XCTAssertTrue(serverChoice.waitForExistence(timeout: 5))
        serverChoice.tap()

        let runningWorkspace = app.buttons["coder-workspace-Running-Dev"]
        XCTAssertTrue(runningWorkspace.waitForExistence(timeout: 10))
        runningWorkspace.tap()

        let agentRow = app.buttons["coder-agent-row"]
        scrollToHittable(agentRow)
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "two-agent workspace must surface the agent row")

        let connectDisabled = app.buttons["connect-button"]
        scrollToHittable(connectDisabled)
        XCTAssertFalse(connectDisabled.isEnabled, "ambiguity must block saving until an agent is picked")

        pickAgent("main")

        let persisted = app.buttons["coder-agent-row"]
        scrollToHittable(persisted)
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertTrue(persisted.label.contains("main"), "picked agent name must show in the row (got: \(persisted.label))")

        selectAuthenticationKey("Fixture Ed25519")
        let connect = app.buttons["connect-button"]
        scrollToHittable(connect)
        XCTAssertTrue(connect.isEnabled, "explicit pick unblocks saving")
        connect.tap()

        let terminal = terminalSurface()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "saved multi-agent connection should open the terminal scene")

        relaunch(flags: ["--uitest-coder-multi-agent"])

        let edit = app.buttons["edit-Multi-Agent"].firstMatch
        let row = waitForRow(named: "Multi Agent")
        scrollToHittable(row)
        row.swipeLeft()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        tap(edit)

        let agentRowAgain = app.buttons["coder-agent-row"]
        scrollToHittable(agentRowAgain)
        XCTAssertTrue(agentRowAgain.waitForExistence(timeout: 5), "persisted agent pick must rehydrate the agent row")
        XCTAssertTrue(agentRowAgain.label.contains("main"), "persisted agent name must survive save/edit round-trip")
    }

    // MARK: - Flow 2: stopped workspace with policy OFF never starts

    func testStoppedWorkspacePolicyOffShowsNotConnectableAndSendsNoStart() {
        launchReset()
        addFixtureServer(name: "Fixture Server")
        createCoderConnection(name: "Policy Off")

        relaunch(flags: ["--uitest-coder-workspace-stopped"])
        connect("Policy Off")

        let message = app.staticTexts["coder-not-connectable-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "stopped workspace with policy off must show the not-connectable screen")
        XCTAssertTrue(message.label.contains("start policy is off"), "error must explain the policy, got: \(message.label)")
        XCTAssertEqual(startPostCount(), 0, "policy OFF must send no start POST")

        tap(app.buttons["coder-not-connectable-close"])
    }

    // MARK: - Flow 3: policy ON starts exactly once and connects after ready

    func testPolicyOnStartsExactlyOnceAndConnectsAfterReady() {
        launchReset()
        addFixtureServer(name: "Fixture Server")
        createCoderConnection(name: "Policy On", startPolicy: true)

        relaunch(flags: [
            "--uitest-coder-workspace-stopped",
            "--uitest-coder-start-pending-once",
        ])
        connect("Policy On")

        let buildLayer = app.staticTexts["coder-start-layer-build"]
        XCTAssertTrue(buildLayer.waitForExistence(timeout: 10), "policy ON must show the layered start progress")
        XCTAssertTrue(app.staticTexts["coder-start-layer-agent-lifecycle"].waitForExistence(timeout: 5))
        XCTAssertEqual(startPostCount(), 1, "exactly one start POST must be sent")

        let terminal = terminalSurface()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "connection must open the session after the workspace is ready")
    }

    // MARK: - Flow 4a: dormancy requires explicit user action

    func testDormantWorkspaceShowsActionRequiredWithoutMutation() {
        launchReset()
        addFixtureServer(name: "Fixture Server")
        createCoderConnection(name: "Dormant Case", startPolicy: true)

        relaunch(flags: ["--uitest-coder-dormant"])
        connect("Dormant Case")

        let message = app.staticTexts["coder-action-required-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "dormant workspace must show the action-required screen")
        XCTAssertTrue(message.label.contains("dormant"), "message must name dormancy, got: \(message.label)")
        XCTAssertEqual(startPostCount(), 0, "dormant workspace must not be mutated or started")

        tap(app.buttons["coder-action-required-close"])
    }

    // MARK: - Flow 4b: parameter mismatch requires explicit user answers

    func testParameterMismatchShowsActionRequiredWithoutStart() {
        launchReset()
        addFixtureServer(name: "Fixture Server")
        createCoderConnection(name: "Param Case", startPolicy: true)

        relaunch(flags: [
            "--uitest-coder-workspace-stopped",
            "--uitest-coder-param-mismatch",
        ])
        connect("Param Case")

        let message = app.staticTexts["coder-action-required-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "parameter mismatch must show the action-required screen")
        XCTAssertTrue(message.label.contains("parameter"), "message must name the parameter requirement, got: \(message.label)")
        XCTAssertEqual(startPostCount(), 0, "parameter mismatch must not produce a start POST")

        tap(app.buttons["coder-action-required-close"])
    }

    // MARK: - Session info diagnostics row

    func testSessionInfoShowsPathWorkspaceAgentAndServerVersion() {
        launchReset()
        addFixtureServer(name: "Fixture Server")
        createCoderConnection(name: "Info Case")

        relaunch(flags: ["--uitest-coder-netpath-relayed"])
        connect("Info Case")

        let terminal = terminalSurface()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))

        let info = app.buttons["scene-coder-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()

        let path = app.staticTexts["coder-info-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.label, "Relayed", "networkPathChanged event must surface in the info row")

        let server = app.staticTexts["coder-info-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertTrue(server.label.contains("v2.36.4-uitest"), "server version must come from buildinfo, got: \(server.label)")

        XCTAssertTrue(app.staticTexts["coder-info-workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["coder-info-agent"].waitForExistence(timeout: 5))
    }
}

private extension XCUIElement {
    func clearText() {
        guard let current = value as? String, !current.isEmpty else { return }
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 20)
        typeText(deletes)
    }
}
