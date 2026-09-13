import Foundation
import XCTest

/// T9 herd machine switcher. The live E2E runs against BOTH fixture servers
/// (start with `scripts/fixtures-up.sh`): opening the herd connects both
/// machines, switching chips streams input only to the selected machine
/// (needle echo per machine + per-machine cwd pane labels), and killing one
/// server dims exactly that machine while the other keeps working. The
/// layout check renders five chips with no fixtures at all.
@MainActor
final class HerdSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Switcher layout (no fixtures required)

    func testFiveMachineLayoutScrollsHorizontally() {
        app.launchArguments = ["--uitest-herd-layout"]
        app.launch()

        let row = app.buttons["herd-Layout-Herd"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the layout herd must be seeded")
        row.tap()

        let bar = app.descendants(matching: .any)["herd-machine-bar"]
        XCTAssertTrue(
            bar.waitForExistence(timeout: 15),
            "the herd workspace opens with the machine switcher bar"
        )
        for index in 1...5 {
            let chip = app.buttons["herd-chip-Layout-\(index)"]
            XCTAssertTrue(
                chip.waitForExistence(timeout: 10),
                "machine \(index) renders a chip"
            )
            XCTAssertTrue(
                chip.label.contains("Offline"),
                "unresolvable machines read Offline, never a color-only cue: \(chip.label)"
            )
        }
        XCTAssertTrue(
            app.buttons["herd-chip-Layout-1"].isSelected,
            "the first machine is selected when no persisted choice exists"
        )
        attachScreenshot("herd-switcher-five-machines")
    }

    // MARK: - Live E2E (both fixture servers)

    func testTwoMachineHerdSwitchesAndSurvivesOneServerDeath() throws {
        try XCTSkipUnless(fixturesAvailable(), "requires fixtures-up with both herdr servers")

        app.launchArguments = [
            "--uitest-reset",
            "--uitest-herd-reset",
            "--uitest-seed-keys",
            "--uitest-pretrust-fixtures",
            "--uitest-herdr-live",
            "--uitest-herd-e2e",
            "--uitest-herd-fixture",
            "--uitest-hwkeys", "text:Ab1, await:echo:chip:Herd Beta, text:Cd9",
        ]
        app.launch()

        // The reset launch re-seeds connections and herds right as the
        // first rows appear; a tap synthesized into that rebuild can be
        // dropped by the list's re-render. Wait for the seeded state to
        // settle, and retry the tap once if the workspace didn't present.
        XCTAssertTrue(
            app.buttons["connection-Herd-Alpha"].waitForExistence(timeout: 15),
            "the machine connections must be seeded"
        )
        let herdRow = app.buttons["herd-Fixture-Herd"]
        XCTAssertTrue(herdRow.waitForExistence(timeout: 15), "the seeded herd must be listed")
        waitUntil(herdRow, contains: "2 machines")
        openHerdWorkspace(byTapping: herdRow)

        let alphaChip = app.buttons["herd-chip-Herd-Alpha"]
        let betaChip = app.buttons["herd-chip-Herd-Beta"]
        XCTAssertTrue(
            app.descendants(matching: .any)["herd-machine-bar"].waitForExistence(timeout: 15),
            "the herd workspace opens behind the machine bar"
        )
        XCTAssertTrue(alphaChip.waitForExistence(timeout: 10))
        XCTAssertTrue(betaChip.waitForExistence(timeout: 10))

        waitUntil(alphaChip, contains: "Online", timeout: 75)
        waitUntil(betaChip, contains: "Online", timeout: 75, message: "both machines connect")
        waitUntil(
            app.staticTexts["herdr-lifecycle-echo"],
            contains: "online:herd/",
            message: "the lifecycle log carries the herd endpoint identity"
        )

        waitUntil(alphaChip, contains: "selected", message: "Alpha (first machine) is selected on open")
        XCTAssertTrue(
            firstPane().waitForExistence(timeout: 30),
            "the selected machine's committed surface renders panes"
        )

        // Needle one: the injector types only once the SELECTED machine
        // (Alpha) is online with a committed surface — the text streams to
        // Alpha's endpoint through its own input gate.
        waitUntil(
            app.staticTexts["herdr-input-echo"],
            contains: "text(\"A\"",
        )
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "text(\"1\"")

        // Switch machines: selection traits move, the app records the
        // switch, and the injector's next needle is GATED on that record —
        // so needle two provably streams to Beta, never Alpha.
        betaChip.tap()
        waitUntil(betaChip, contains: "selected", message: "tapping a chip selects that machine")
        XCTAssertFalse(
            alphaChip.label.contains("selected"),
            "the previous machine loses selection: \(alphaChip.label)"
        )
        XCTAssertTrue(
            firstPane().waitForExistence(timeout: 30),
            "the newly selected machine's surface renders"
        )
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "chip:Herd Beta")

        // Needle two: gated on the selection switch, so it lands on Beta.
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "text(\"C\"")
        waitUntil(app.staticTexts["herdr-input-echo"], contains: "text(\"9\"")
        attachScreenshot("herd-two-machines-online")

        // Kill Beta's herdr server: only Beta dims; Alpha keeps its
        // session. (Deterministic only from a clean fixture state —
        // lingering bridge-spawned servers make the pidfile stale, so
        // restart fixtures before this suite.)
        try killFixtureServer(port: 12223)

        waitUntil(
            betaChip,
            contains: "Offline",
            timeout: 75,
            message: "the killed machine settles Offline (cached state, input disabled)"
        )
        waitUntil(alphaChip, contains: "Online", message: "the other machine is unaffected")

        betaChip.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-diagnostic"].waitForExistence(timeout: 30),
            "selecting the dead machine shows its typed diagnostic (input disabled)"
        )
        attachScreenshot("herd-one-machine-dead")

        alphaChip.tap()
        XCTAssertTrue(
            firstPane().waitForExistence(timeout: 30),
            "Alpha's session keeps rendering after the other machine died"
        )
        waitUntil(alphaChip, contains: "Online")
    }

    // MARK: - First-contact trust (F3-B)

    /// A herd's machines connect in the background AFTER the workspace
    /// cover is already up, so their first-contact TOFU challenges must
    /// present ABOVE the cover (same ``HostTrustPromptView`` surface Mode A
    /// uses) — never trapped behind it leaving the machine "Connecting"
    /// forever. Two first-contact machines also exercise the sequential
    /// decision queue: one prompt at a time, both machines reachable.
    func testFirstContactHerdSurfacesTrustPromptAboveTheCoverAndGoesOnline() throws {
        try XCTSkipUnless(fixturesAvailable(), "requires fixtures-up with both herdr servers")

        app.launchArguments = [
            "--uitest-reset",
            "--uitest-herd-reset",
            "--uitest-seed-keys",
            "--uitest-pretrust-fixtures",
            "--uitest-herdr-live",
            "--uitest-herd-e2e",
            "--uitest-herd-fixture",
            "--uitest-herdr-untrusted",
        ]
        app.launch()

        let herdRow = app.buttons["herd-Fixture-Herd"]
        XCTAssertTrue(herdRow.waitForExistence(timeout: 15), "the seeded herd must be listed")
        waitUntil(herdRow, contains: "2 machines")
        openHerdWorkspace(byTapping: herdRow)

        let bar = app.descendants(matching: .any)["herd-machine-bar"]
        XCTAssertTrue(
            bar.waitForExistence(timeout: 15),
            "the herd workspace cover must be up before the challenges arrive"
        )

        for machine in 1...2 {
            let prompt = app.staticTexts["trust-prompt"]
            XCTAssertTrue(
                prompt.waitForExistence(timeout: 20),
                "machine \(machine): the first-contact TOFU prompt must surface above the herd cover"
            )
            XCTAssertTrue(bar.exists, "the workspace stays mounted under the prompt")
            // The same prompt sheet mounts on every window watching this
            // coordinator (herdr window presenter + main-window backstop);
            // either copy resolves the same challenge, so firstMatch is safe.
            waitUntil(app.staticTexts["trust-host"].firstMatch, contains: "127.0.0.1")
            app.buttons["trust-confirm"].firstMatch.tap()
        }

        let alphaChip = app.buttons["herd-chip-Herd-Alpha"]
        let betaChip = app.buttons["herd-chip-Herd-Beta"]
        waitUntil(
            alphaChip,
            contains: "Online",
            timeout: 75,
            message: "the trusted Alpha machine comes online"
        )
        waitUntil(
            betaChip,
            contains: "Online",
            timeout: 75,
            message: "the trusted Beta machine comes online — no continuation stranded by the cover"
        )
        attachScreenshot("herd-trust-both-machines-online")
    }

    // MARK: Helpers

    /// Opens the herd workspace from a list row, retrying the tap once —
    /// the list can swallow a tap that lands mid-re-render.
    private func openHerdWorkspace(byTapping row: XCUIElement) {
        let bar = app.descendants(matching: .any)["herd-machine-bar"]
        row.tap()
        if !bar.waitForExistence(timeout: 8) {
            row.tap()
            XCTAssertTrue(
                bar.waitForExistence(timeout: 15),
                "tapping the herd row must open the herd workspace"
            )
        }
    }

    private func fixturesAvailable() -> Bool {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let run = repoRoot.appendingPathComponent("Fixtures/run/herdr")
        return FileManager.default.fileExists(
            atPath: run.appendingPathComponent("server-12222/herdr-client.sock").path
        )
        && FileManager.default.fileExists(
            atPath: run.appendingPathComponent("server-12223/herdr-client.sock").path
        )
    }

    private func killFixtureServer(port: Int) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pidFile = repoRoot.appendingPathComponent("Fixtures/run/herdr/server-\(port)/server.pid")
        let pid = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The UI-test runner is a host-side process sharing the simulator's
        // PID namespace, and the fixture server runs as the same user — a
        // POSIX kill reaches it without Process (unavailable in the iOS
        // SDK's Foundation). fixtures-up restores the server afterward.
        guard let value = pid_t(pid) else {
            throw XCTSkip("unreadable pidfile for server \(port)")
        }
        let result = Darwin.kill(value, SIGKILL)
        XCTAssertEqual(result, 0, "killing the fixture server must succeed (errno \(errno))")
    }

    private func firstPane() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "herdr-pane-")
        ).firstMatch
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

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
