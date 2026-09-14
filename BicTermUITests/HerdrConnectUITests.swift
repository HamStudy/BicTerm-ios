import XCTest

/// Mode A embed E2E (plan herdr-embed T7). The native Mode A UI is gone;
/// this file exercises the same shipped flow against the embedded TUI:
/// connect from a herdr-enabled connection → SSH bridge carrier establishes
/// through BicTermCore (TOFU prompt surfaces through the shared
/// HostTrustPromptView) → the embedded real-herdr client boots → typed
/// keystrokes reach the client. Requires fixtures-up with the prebuilt
/// herdr v0.9.0 server (`scripts/herdr-server-fetch.sh`,
/// `HERDR_LOSSY=12322:delay=80ms scripts/fixtures-up.sh`).
@MainActor
final class HerdrConnectUITests: XCTestCase {
    private static let hop1HostFingerprint = "SHA256:pT2cNum6IkFhCplSQfWE5oW2CU4Bg51qD1/1HtirjBs"

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testHerdrConnectTrustsHostAndReachesEmbeddedClientRunning() {
        launch(
            extra: [
                "--uitest-herdr-live",
                "--uitest-herdr-untrusted",
            ],
            port: nil
        )

        let row = app.buttons["connection-Herdr-Alpha"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded herdr connection must be listed")
        XCTAssertTrue(app.staticTexts["badge-herdr"].exists, "the seeded connection is herdr-enabled")

        swipeRow(named: "Herdr-Alpha")
        app.buttons["connect-Herdr-Alpha"].tap()

        // Fresh in-memory trust store: TOFU must surface through the same
        // host-key approval view terminal sessions use.
        let prompt = app.staticTexts["trust-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "first contact must surface the trust prompt")
        waitUntil(app.staticTexts["trust-host"], contains: "127.0.0.1")
        waitUntil(app.staticTexts["trust-port"], contains: "12222")
        waitUntil(
            app.staticTexts["trust-fingerprint"],
            contains: Self.hop1HostFingerprint,
            message: "prompt must show hop-1's committed host key"
        )
        attachScreenshot("herdr-embed-trust-prompt")
        app.buttons["trust-confirm"].tap()

        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "embedded client running"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [running], timeout: 60),
            .completed,
            "embedded client must reach running (status: \(status.label))"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-embed-tui"].waitForExistence(timeout: 10),
            "the embedded SwiftTerm surface must be present"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-endpoint-label"].waitForExistence(timeout: 5),
            "the embed chrome names its connection"
        )
        waitUntil(
            app.descendants(matching: .any)["herdr-endpoint-label"],
            contains: "Herdr Alpha",
            message: "the embed header must name the seeded connection"
        )

        // Keystroke acceptance: the io counter's write side must advance
        // after keys reach the embedded client (the same DEBUG-only strip
        // HerdrEmbedUITests uses on the cover path).
        let before = ioWriteCount(app)
        app.typeText("Z")
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ioMarker(after: before)),
            object: app.descendants(matching: .any)["herdr-embed-io"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 10),
            .completed,
            "keystroke must reach the embedded client"
        )
        attachScreenshot("herdr-embed-running")
    }

    func testUnreachableHostSurfacesTypedTransportDiagnostic() {
        launch(extra: [], port: 12299)

        connectSeededHerdrAlpha()
        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "failed"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [failed], timeout: 30),
            .completed,
            "an unreachable SSH host must land the embed run in failed state (status: \(status.label))"
        )
        let failedMessage = app.descendants(matching: .any)["herdr-embed-failed"]
        XCTAssertTrue(failedMessage.waitForExistence(timeout: 5))
        waitUntil(
            failedMessage,
            contains: "unreachable",
            message: "the typed transport-lost diagnostic must surface"
        )
        attachScreenshot("herdr-embed-unreachable")
    }

    func testProbeMissingSurfacesIncompatibleGeneration() {
        launch(extra: ["--uitest-herdr-live", "--uitest-herdr-probe-missing"], port: nil)

        connectSeededHerdrAlpha()
        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "failed"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [failed], timeout: 30),
            .completed,
            "a probe-incompatible endpoint must land the embed run in failed state (status: \(status.label))"
        )
        let failedMessage = app.descendants(matching: .any)["herdr-embed-failed"]
        XCTAssertTrue(failedMessage.waitForExistence(timeout: 5))
        XCTAssertFalse(
            failedMessage.label.isEmpty,
            "the embed failure screen must carry a non-empty diagnostic"
        )
        attachScreenshot("herdr-embed-probe-missing")
    }

    /// Requires the fixture knob `HERDR_SERVERS="12222"` (12223's herdr
    /// server stopped, sshd still up). The honest assertion is a TYPED
    /// terminal state — running after the client bridges through (the
    /// fixture binary self-heals a missing server in practice, see
    /// herdr-embed-t6), or a typed diagnostic — never a silent hang.
    func testMissingHerdrServerReachesTypedEmbedState() throws {
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
        let status = app.descendants(matching: .any)["herdr-embed-status"]

        var reachedTypedState = false
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline && !reachedTypedState {
            if status.exists,
               status.label == "embedded client running" || status.label == "failed" {
                reachedTypedState = true
            }
            if !reachedTypedState { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(
            reachedTypedState,
            "a missing herdr server must terminate in a typed state, never hang (status: \(status.label))"
        )
        attachScreenshot("herdr-embed-missing-server")
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
