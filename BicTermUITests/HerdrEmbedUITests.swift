import XCTest

/// T4 embedded-herdr smoke: the REAL herdr TUI client runs in-process and
/// renders into the SwiftTerm surface on the iPhone cover path. Requires
/// the fixture herdr server (scripts/herdr-server-fetch.sh +
/// scripts/fixtures-up.sh); the socket is injected through the app's
/// environment. Skips when the fixture is down so the rest of the UI suite
/// stays runnable.
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

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            fixtureIsUp,
            "herdr fixture server not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )
    }

    func testEmbeddedTUIRendersAndAcceptsKeys() throws {
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
