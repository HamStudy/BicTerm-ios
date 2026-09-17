import XCTest

/// T4 embedded-herdr smoke: the REAL herdr TUI client runs in-process and
/// renders into the SwiftTerm surface on the iPhone cover path. Requires
/// the fixture herdr server (scripts/herdr-server-fetch.sh +
/// scripts/fixtures-up.sh); the socket is injected through the app's
/// environment. The fixture-dependent tests skip when the fixture is down
/// so the rest of the UI suite stays runnable; the chrome test does not
/// need the fixture (the chrome renders in every runtime phase).
final class HerdrEmbedUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var fixtureSocket: String {
        Self.repoRoot
            .appendingPathComponent("Fixtures/run/herdr/server-12222/herdr-client.sock")
            .path
    }

    private var fixtureIsUp: Bool {
        FileManager.default.fileExists(atPath: fixtureSocket)
    }

    private let fixtureSkipMessage =
        "herdr fixture server not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The workspace presents the SAME top chrome as a terminal session:
    /// title + Herdr badge + status leading; the session menu (ellipsis)
    /// and Close trailing. The menu is the real SessionMenuView with
    /// `-herdr`-suffixed identifiers (a terminal window and a herdr window
    /// can share the iPad screen) — its Terminal Toolbar item carries live
    /// On/Off state and governs the herdr surface's accessory strip. A
    /// workspace is not a SessionStore session, so the per-session
    /// Appearance submenu must NOT appear.
    func testWorkspaceChromeMenuToggleAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-embed"]
        if fixtureIsUp {
            app.launchEnvironment["HERDR_EMBED_SOCKET_PATH"] = fixtureSocket
        }
        app.launch()

        let menu = app.buttons["scene-menu-herdr"]
        XCTAssertTrue(
            menu.waitForExistence(timeout: 30),
            "the herdr workspace chrome must carry the session menu"
        )
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(
            app.buttons["scene-close-Fixture-herdr"].exists,
            "the herdr workspace chrome must carry Close"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-endpoint-label"].waitForExistence(timeout: 5),
            "the herdr chrome must name its workspace"
        )

        XCTAssertTrue(openHerdrMenu(app), "herdr session menu never opened")
        let toggle = app.buttons["terminal-toolbar-toggle-herdr"]
        XCTAssertTrue(toggle.exists, "the menu must list the Terminal Toolbar toggle")
        let before = toggle.label
        XCTAssertTrue(
            before.hasPrefix("Terminal Toolbar: "),
            "the toggle must show its live On/Off state: \(before)"
        )
        XCTAssertTrue(app.buttons["scene-sessions-herdr"].exists)
        XCTAssertTrue(app.buttons["scene-new-session-herdr"].exists)
        XCTAssertTrue(app.buttons["scene-settings-herdr"].exists)
        XCTAssertFalse(
            app.buttons["session-appearance-theme"].exists,
            "herdr workspaces are not store sessions — the Appearance submenu must stay hidden"
        )
        let wasOn = before.hasSuffix("On")
        toggle.tap()

        // The accessory strip follows the toggle on the live herdr surface
        // (layout participant, never an overlay) — assertable only when the
        // fixture-backed client actually reached running.
        if fixtureIsUp {
            XCTAssertTrue(
                app.descendants(matching: .any)["herdr-embed-tui"].waitForExistence(timeout: 20),
                "SwiftTerm surface for the embedded TUI exists"
            )
            let accessory = app.descendants(matching: .any)["terminal-accessory"]
            if wasOn {
                XCTAssertTrue(accessory.waitForNonExistence(timeout: 10), "the strip must hide with the toggle")
            } else {
                XCTAssertTrue(accessory.waitForExistence(timeout: 10), "the strip must show with the toggle")
            }
        }

        XCTAssertTrue(openHerdrMenu(app), "herdr session menu never reopened")
        XCTAssertEqual(
            toggle.label.hasSuffix("On"),
            !wasOn,
            "the toggle state must flip with the model: \(before) → \(toggle.label)"
        )
    }

    /// Taps the chrome's menu button and waits for the Sessions submenu
    /// item — the same convergence loop SessionMenuUITests uses (re-tapping
    /// closes an already-open menu, so failed attempts retry cleanly).
    private func openHerdrMenu(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = app.buttons.matching(identifier: "scene-menu-herdr")
            for index in 0..<candidates.count where candidates.element(boundBy: index).isHittable {
                candidates.element(boundBy: index).tap()
                if app.buttons["scene-sessions-herdr"].waitForExistence(timeout: 5) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func testEmbeddedTUIRendersAndAcceptsKeys() throws {
        try XCTSkipUnless(fixtureIsUp, fixtureSkipMessage)
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-embed"]
        app.launchEnvironment["HERDR_EMBED_SOCKET_PATH"] = fixtureSocket
        app.launch()

        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "embedded client running"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [running], timeout: 20),
            .completed,
            "embedded client reached running (status: \(status.label))"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-embed-tui"].waitForExistence(timeout: 10),
            "SwiftTerm surface for the embedded TUI exists"
        )

        // Keystroke acceptance: the io counter's write side must move off
        // zero after a key reaches the embedded client.
        let before = ioWriteCount(app)
        app.typeText("j")
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ioMarker(after: before)),
            object: app.descendants(matching: .any)["herdr-embed-io"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 10),
            .completed,
            "keystroke reached the embedded client (io strip did not advance)"
        )
    }

    /// Landscape parity (plan herdr-embed T7): the embed chrome + SwiftTerm
    /// surface must re-layout coherently when the device rotates. Sets
    /// `XCUIDevice` orientation, then waits for the embed run to reach
    /// running — same fixtures, same surface contract as the portrait test.
    func testEmbeddedTUIReachesRunningInLandscape() throws {
        try XCTSkipUnless(fixtureIsUp, fixtureSkipMessage)
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-embed"]
        app.launchEnvironment["HERDR_EMBED_SOCKET_PATH"] = fixtureSocket
        app.launch()

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "embedded client running"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [running], timeout: 20),
            .completed,
            "embedded client reached running in landscape (status: \(status.label))"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "herdr-embed-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The DEBUG io strip reads `embed io ↑<written> ↓<read>`; the write
    /// count strictly increases after a keystroke, so parse it out.
    private func ioWriteCount(_ app: XCUIApplication) -> Int {
        let label = app.descendants(matching: .any)["herdr-embed-io"].label
        guard let range = label.range(of: "↑") else { return 0 }
        let tail = label[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func ioMarker(after count: Int) -> String {
        "↑\(count + 1)"
    }
}
