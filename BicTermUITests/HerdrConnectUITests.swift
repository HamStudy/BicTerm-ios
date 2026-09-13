import XCTest

/// T6 Mode A connect-flow UI tests. The live E2E runs against the real
/// fixture sshd + prebuilt herdr 0.9.0 server on 12222 (start with
/// `scripts/fixtures-up.sh`); the idempotency and diagnostic scenarios
/// exercise the same surface with deterministic failures. The needle-echo
/// assertion reads the DEBUG input echo strip — per-grapheme commits
/// through the real input lane, which the gate only accepts once the
/// endpoint is online with a committed surface.
@MainActor
final class HerdrConnectUITests: XCTestCase {
    private static let hop1HostFingerprint = "SHA256:pT2cNum6IkFhCplSQfWE5oW2CU4Bg51qD1/1HtirjBs"

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Live E2E (fixture server on 12222)

    func testHerdrConnectTrustsHostAndReachesOnlineWithNeedleEcho() {
        launch(
            extra: [
                "--uitest-herdr-live",
                "--uitest-herdr-untrusted",
                "--uitest-hwkeys", "text:Zq9x",
            ],
            port: nil
        )

        let row = app.buttons["connection-Herdr-Alpha"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded herdr connection must be listed")
        XCTAssertTrue(app.staticTexts["badge-herdr"].exists, "the seeded connection is herdr-enabled")

        swipeRow(named: "Herdr-Alpha")
        app.buttons["connect-Herdr-Alpha"].tap()

        // Fresh in-memory trust store (--uitest-herdr-untrusted): the TOFU
        // prompt must surface through the same host-key approval surface
        // terminal sessions use.
        let prompt = app.staticTexts["trust-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "first contact must surface the trust prompt")
        waitUntil(app.staticTexts["trust-host"], contains: "127.0.0.1")
        waitUntil(app.staticTexts["trust-port"], contains: "12222")
        waitUntil(
            app.staticTexts["trust-fingerprint"],
            contains: Self.hop1HostFingerprint,
            message: "prompt must show hop-1's committed host key"
        )
        attachScreenshot("herdr-trust-prompt")
        app.buttons["trust-confirm"].tap()

        waitForOnline(timeout: 60)

        waitUntil(
            app.descendants(matching: .any)["herdr-endpoint-label"],
            contains: "Herdr Alpha",
            message: "the workspace names its connection"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "herdr-pane-")
            ).firstMatch.waitForExistence(timeout: 15),
            "the live server's committed surface must render panes"
        )
        waitUntil(
            app.staticTexts["herdr-lifecycle-echo"],
            contains: "online:connection/",
            message: "the lifecycle log records the live endpoint generation"
        )

        // Needle echo: the injector commits one grapheme at a time; the
        // first and last characters bracket the whole needle.
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "text(\"Z\"", message: "needle head")
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "text(\"x\"→", message: "needle tail")
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-input-note"].exists,
            "a successful send never raises the note strip"
        )
        attachScreenshot("herdr-live-workspace")
    }

    func testRepeatedConnectTapsYieldExactlyOneAttempt() {
        // The double-tap is fired app-side (--uitest-herdr-double-connect):
        // two handleConnect calls in one turn, the strictest form of a
        // double-tap — XCUI cannot deliver a second tap on swipe actions
        // that close within ~1s of the first.
        launch(extra: ["--uitest-herdr-live", "--uitest-herdr-double-connect"], port: nil)

        let row = app.buttons["connection-Herdr-Alpha"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        swipeRow(named: "Herdr-Alpha")
        let connect = app.buttons["connect-Herdr-Alpha"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()

        waitForOnline(timeout: 60)

        app.descendants(matching: .any)["herdr-disconnect"].tap()
        XCTAssertTrue(
            app.buttons["add-connection"].waitForExistence(timeout: 15),
            "disconnecting must return to the connection list"
        )
        // Every open window's connection list renders this strip (the herdr
        // window's fallback list shows its own coordinator's count of 0);
        // exactly one attempt means the connecting window's strip reads 1.
        let attempts = app.staticTexts.matching(identifier: "herdr-connect-attempts")
        XCTAssertTrue(
            (0..<attempts.count).contains { attempts.element(boundBy: $0).label == "1" },
            "repeated taps while one attempt is in flight must yield exactly one attempt"
        )
    }

    // MARK: - Typed diagnostics (deterministic, no fixture server needed)

    func testUnreachableHostSurfacesTypedTransportDiagnostic() {
        launch(extra: [], port: 12299)

        connectSeededHerdrAlpha()
        let diagnostic = app.descendants(matching: .any)["herdr-diagnostic"]
        XCTAssertTrue(
            diagnostic.waitForExistence(timeout: 30),
            "an unreachable SSH host must surface the typed diagnostic screen"
        )
        waitUntil(
            app.descendants(matching: .any)["herdr-diagnostic-title"],
            contains: "Connection lost",
            message: "SSH establish failures map to transportLost"
        )
        waitUntil(
            app.descendants(matching: .any)["herdr-diagnostic-detail"],
            contains: "unreachable",
            message: "the typed cause is shown"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-probe-diagnostic"].exists,
            "no probe ran — the probe screen must not render"
        )
        attachScreenshot("herdr-unreachable-diagnostic")
    }

    func testHostWithoutHerdrSurfacesProbeDiagnosticScreen() {
        launch(extra: ["--uitest-herdr-live", "--uitest-herdr-probe-missing"], port: nil)

        connectSeededHerdrAlpha()
        let screen = app.descendants(matching: .any)["herdr-probe-diagnostic"]
        XCTAssertTrue(
            screen.waitForExistence(timeout: 30),
            "a probe-incompatible endpoint must open the probe diagnostic screen"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["herdr-probe-title"].label,
            "No Herdr found on the host"
        )
        XCTAssertTrue(app.descendants(matching: .any)["herdr-probe-host"].label.contains("127.0.0.1"))
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-reattach"].exists,
            "no bridge channel exists to re-attach to"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-diagnostic"].exists,
            "the probe screen is not the generic diagnostic"
        )
        attachScreenshot("herdr-probe-missing-diagnostic")
    }

    /// Requires the fixture knob `HERDR_SERVERS="12222"` (12223's herdr
    /// server stopped, sshd still up). herdr 0.9.0 self-heals a missing
    /// server through its own daemon spawner (observed: the fixture binary
    /// respawns bound to the same HERDR_SOCKET_PATH), so the honest
    /// assertion is a TYPED terminal state — Online after the self-heal, or
    /// a typed diagnostic (the handshake watchdog when the heal loses the
    /// race) — never a silent hang. Self-validates the fixture state (the
    /// runner reads the repo FS like the app reads fixture dirs) so the
    /// suite stays green with both fixture servers running.
    func testMissingHerdrServerTerminatesInTypedState() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRun = repoRoot.appendingPathComponent("Fixtures/run/herdr")
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: fixtureRun.appendingPathComponent("server-12222/herdr-client.sock").path)
                && !fm.fileExists(atPath: fixtureRun.appendingPathComponent("server-12223/herdr-client.sock").path),
            "requires fixtures-up with HERDR_SERVERS=12222 (12223 has no herdr server)"
        )
        launch(extra: ["--uitest-herdr-live"], port: 12223)

        connectSeededHerdrAlpha()
        let badge = app.descendants(matching: .any)["herdr-status-badge"]
        let diagnostic = app.descendants(matching: .any)["herdr-diagnostic"]

        var reachedTypedState = false
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline && !reachedTypedState {
            if badge.exists, badge.label == "Online" { reachedTypedState = true }
            if diagnostic.exists { reachedTypedState = true }
            if !reachedTypedState { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(
            reachedTypedState,
            "a missing herdr server must terminate in a typed state (Online after self-heal or a diagnostic), never hang"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr-probe-diagnostic"].exists,
            "the probe succeeded — the probe screen must not render"
        )
        attachScreenshot("herdr-missing-server-typed-state")
    }

    // MARK: Helpers

    private func launch(extra: [String], port: Int?) {
        var arguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-pretrust-fixtures",
            "--uitest-herdr-connection",
        ]
        if let port {
            arguments += ["--uitest-herdr-connection-port", String(port)]
        }
        arguments += extra
        app.launchArguments = arguments
        app.launch()
    }

    private func connectSeededHerdrAlpha() {
        let row = app.buttons["connection-Herdr-Alpha"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded herdr connection must be listed")
        swipeRow(named: "Herdr-Alpha")
        let connect = app.buttons["connect-Herdr-Alpha"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
    }

    private func waitForOnline(timeout: TimeInterval) {
        let badge = app.descendants(matching: .any)["herdr-status-badge"]
        let online = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Online"),
            object: badge
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [online], timeout: timeout), .completed,
            "the endpoint must reach Online (badge: \(badge.label))"
        )
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
