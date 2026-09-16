import UIKit
import XCTest

/// T14 behavioral coverage: multi-window session scenes, restoration
/// semantics, and agent approval prompts, exercised against the real
/// fixture sshd instances (hop1=12222, hop2=12223).
@MainActor
final class SessionScenesUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let agentClient = repoRoot
        .appendingPathComponent("Fixtures/agent/agent_client.py").path
    private static let fixturePublicKey = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519.pub").path

    /// Deterministic fingerprint of the committed fixture ed25519 key.
    private static let fixtureFingerprint = "SHA256:+r0XE2pE/ZCcOeGWrisHbWLLrEFKapNtuqH9LUZ7QqU"

    /// Committed fixture HOST key fingerprints (sshd hop1/hop2).
    private static let hop1HostFingerprint = "SHA256:pT2cNum6IkFhCplSQfWE5oW2CU4Bg51qD1/1HtirjBs"
    private static let hop2HostFingerprint = "SHA256:e/cQVX7KMwmF6GMu3vZ7MiFagU08GD2jS/a21q9/XAM"

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func baseLaunchArguments(
        command: String? = nil,
        extra: [String] = [],
        pretrust: Bool = true
    ) -> [String] {
        var arguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
        ]
        if pretrust {
            arguments.append("--uitest-pretrust-fixtures")
        }
        if let command {
            arguments += ["--uitest-session-command", command]
        }
        arguments += extra
        return arguments
    }

    private func agentSignCommand(data: String) -> String {
        "python3 \(Self.agentClient) sign \(Self.fixturePublicKey) \(data)"
    }

    @discardableResult
    private func waitUntil(
        _ element: XCUIElement,
        contains marker: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label(of: element).contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return label(of: element).contains(marker)
    }

    /// SwiftUI Texts report an EMPTY `value` to XCUI — the content lives in
    /// `label`. Prefer a non-empty value, fall back to the label.
    private func label(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Two scenes

    /// iPad: two terminal windows carry two independent sessions — each
    /// scene's output shows its own marker and never the other scene's.
    func testTwoScenesShowDistinctTerminalContent() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Two-window scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            command: "echo __MARKER_{NAME}__",
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        let alphaTail = app.staticTexts["scene-tail-Alpha"]
        let betaTail = app.staticTexts["scene-tail-Beta"]
        XCTAssertTrue(alphaTail.waitForExistence(timeout: 60), "Alpha scene never appeared")
        XCTAssertTrue(betaTail.waitForExistence(timeout: 60), "Beta scene never appeared")

        let alphaHasMarker = waitUntil(alphaTail, contains: "__MARKER_Alpha__", timeout: 45)
        let betaHasMarker = waitUntil(betaTail, contains: "__MARKER_Beta__", timeout: 45)
        XCTAssertTrue(alphaHasMarker, "Alpha tail never showed its marker: \(label(of: alphaTail))")
        XCTAssertTrue(betaHasMarker, "Beta tail never showed its marker: \(label(of: betaTail))")

        let alphaText = label(of: alphaTail)
        let betaText = label(of: betaTail)
        XCTAssertFalse(
            alphaText.contains("__MARKER_Beta__"),
            "cross-scene leakage: Beta marker visible in Alpha's scene"
        )
        XCTAssertFalse(
            betaText.contains("__MARKER_Alpha__"),
            "cross-scene leakage: Alpha marker visible in Beta's scene"
        )

        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 30),
            "Alpha scene status: \(label(of: app.staticTexts["scene-status-Alpha"]))"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Beta"], contains: "status:active", timeout: 30),
            "Beta scene status: \(label(of: app.staticTexts["scene-status-Beta"]))"
        )

        XCTAssertTrue(app.staticTexts["scene-title-Alpha"].exists)
        XCTAssertTrue(app.staticTexts["badge-ssh"].exists)

        attachScreenshot(named: "task-14-two-scenes")
    }

    /// iPad: rotating the device keeps both scenes' sessions active and
    /// each scene's terminal still shows only its own marker after the
    /// re-layout settles.
    func testRotationKeepsBothScenesActiveWithOwnTerminalContent() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Two-window scenario requires the iPad form factor"
        )
        defer { XCUIDevice.shared.orientation = .portrait }

        app.launchArguments = baseLaunchArguments(
            command: "echo __MARKER_{NAME}__",
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        let alphaTail = app.staticTexts["scene-tail-Alpha"]
        let betaTail = app.staticTexts["scene-tail-Beta"]
        let alphaStatus = app.staticTexts["scene-status-Alpha"]
        let betaStatus = app.staticTexts["scene-status-Beta"]
        XCTAssertTrue(alphaTail.waitForExistence(timeout: 60), "Alpha scene never appeared")
        XCTAssertTrue(betaTail.waitForExistence(timeout: 60), "Beta scene never appeared")

        XCTAssertTrue(
            waitUntil(alphaTail, contains: "__MARKER_Alpha__", timeout: 45),
            "Alpha tail never showed its marker: \(label(of: alphaTail))"
        )
        XCTAssertTrue(
            waitUntil(betaTail, contains: "__MARKER_Beta__", timeout: 45),
            "Beta tail never showed its marker: \(label(of: betaTail))"
        )
        XCTAssertTrue(
            waitUntil(alphaStatus, contains: "status:active", timeout: 30),
            "Alpha not active before rotation: \(label(of: alphaStatus))"
        )
        XCTAssertTrue(
            waitUntil(betaStatus, contains: "status:active", timeout: 30),
            "Beta not active before rotation: \(label(of: betaStatus))"
        )

        XCUIDevice.shared.orientation = .landscapeLeft

        // Wait until the rendered surfaces settle in the new orientation:
        // both scenes' chrome is queryable again AND the window frame is
        // actually landscape.
        let settledDeadline = Date().addingTimeInterval(25)
        var settled = false
        while Date() < settledDeadline && !settled {
            let landscapeFrame = app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            if landscapeFrame,
               app.staticTexts["scene-title-Alpha"].exists,
               app.staticTexts["scene-title-Beta"].exists {
                settled = true
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        XCTAssertTrue(settled, "scene chrome never settled in landscape")

        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 30),
            "Alpha dropped from active after rotation: \(label(of: app.staticTexts["scene-status-Alpha"]))"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Beta"], contains: "status:active", timeout: 30),
            "Beta dropped from active after rotation: \(label(of: app.staticTexts["scene-status-Beta"]))"
        )

        let rotatedAlphaText = label(of: alphaTail)
        let rotatedBetaText = label(of: betaTail)
        XCTAssertTrue(
            rotatedAlphaText.contains("__MARKER_Alpha__"),
            "Alpha lost its own marker after rotation: \(rotatedAlphaText)"
        )
        XCTAssertFalse(
            rotatedAlphaText.contains("__MARKER_Beta__"),
            "cross-scene leakage into Alpha after rotation"
        )
        XCTAssertTrue(
            rotatedBetaText.contains("__MARKER_Beta__"),
            "Beta lost its own marker after rotation: \(rotatedBetaText)"
        )
        XCTAssertFalse(
            rotatedBetaText.contains("__MARKER_Alpha__"),
            "cross-scene leakage into Beta after rotation"
        )

        attachScreenshot(named: "task-14-rotation")
    }

    // MARK: - Host-key trust (TOFU)

    /// First contact with an unknown host (no pretrust): the originating
    /// scene presents host, port, algorithm, and the exact fingerprint;
    /// the explicit Trust gesture connects the session.
    func testUnknownHostTrustPromptTrustsAndConnects() {
        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha"],
            pretrust: false
        )
        app.launch()

        let prompt = app.staticTexts["trust-prompt"]
        XCTAssertTrue(
            prompt.waitForExistence(timeout: 60),
            "unknown host must surface the trust prompt in its scene"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["trust-host"], contains: "127.0.0.1", timeout: 5),
            "prompt must show the dialed host"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["trust-port"], contains: "12222", timeout: 5),
            "prompt must show the dialed port"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["trust-algorithm"], contains: "ssh-ed25519", timeout: 5),
            "prompt must show the host key algorithm"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["trust-fingerprint"], contains: Self.hop1HostFingerprint, timeout: 5),
            "prompt fingerprint mismatch: \(label(of: app.staticTexts["trust-fingerprint"]))"
        )

        attachScreenshot(named: "final-repair-tofu-prompt-trust")

        app.buttons["trust-confirm"].tap()

        let goneDeadline = Date().addingTimeInterval(15)
        while Date() < goneDeadline && prompt.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(prompt.exists, "trust prompt must dismiss after Trust")

        let alphaStatus = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(
            waitUntil(alphaStatus, contains: "status:active", timeout: 60),
            "trusted host must connect after the Trust gesture: \(label(of: alphaStatus))"
        )

        attachScreenshot(named: "final-repair-tofu-connected")
    }

    /// Cancelling the trust prompt never trusts and never opens a shell:
    /// the session stays failed with no reappearing prompt.
    func testUnknownHostTrustCancelNeverConnects() {
        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Beta"],
            pretrust: false
        )
        app.launch()

        let prompt = app.staticTexts["trust-prompt"]
        XCTAssertTrue(
            prompt.waitForExistence(timeout: 60),
            "unknown host must surface the trust prompt"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["trust-fingerprint"], contains: Self.hop2HostFingerprint, timeout: 5),
            "Beta prompt must show hop2's fingerprint: \(label(of: app.staticTexts["trust-fingerprint"]))"
        )

        app.buttons["trust-cancel"].tap()

        let goneDeadline = Date().addingTimeInterval(15)
        while Date() < goneDeadline && prompt.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(prompt.exists, "prompt must dismiss after Cancel")

        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(prompt.exists, "cancelled prompt must not reappear on its own")
        let betaStatus = app.staticTexts["scene-status-Beta"]
        XCTAssertTrue(betaStatus.exists, "scene should still report its failure state")
        XCTAssertFalse(
            label(of: betaStatus).contains("status:active"),
            "cancel must never open a shell: \(label(of: betaStatus))"
        )

        attachScreenshot(named: "final-repair-tofu-cancelled")
    }

    // MARK: - Restoration

    /// After termination, the session reappears as reconnect-required, does
    /// NOT auto-connect, and connects only after the explicit button.
    /// iPhone-routed: iPad relaunches scene-target the last terminal window
    /// without the connection-list window (OS scene-restoration quirk), so
    /// the list-driven restoration flow is exercised on the phone form.
    func testRestoredSessionRequiresManualReconnect() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Restoration list flow runs on the phone form factor"
        )

        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        let alphaStatus = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(
            alphaStatus.waitForExistence(timeout: 60),
            "Alpha scene never appeared on first launch"
        )
        XCTAssertTrue(
            waitUntil(alphaStatus, contains: "status:active", timeout: 45),
            "Alpha never connected on first launch"
        )

        // Background the app (real scene-phase transition → snapshot).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        Thread.sleep(forTimeInterval: 3)
        app.terminate()

        // Relaunch expecting restoration: snapshots preserved, no auto-open.
        app.launchArguments = [
            "--uitest-pretrust-fixtures",
            "--uitest-sessions",
            "--uitest-expect-restore",
        ]
        app.launch()

        let reconnectButton = app.buttons["restorable-reconnect-Alpha"]
        XCTAssertTrue(
            reconnectButton.waitForExistence(timeout: 20),
            "relaunch must list the terminated session as reconnect-required"
        )
        XCTAssertTrue(app.staticTexts["restorable-name-Alpha"].exists)
        XCTAssertTrue(
            app.staticTexts["restorable-state-Alpha"].exists,
            "the entry must state its reconnect-required state"
        )

        // No scene may auto-open: the session must not connect by itself.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(
            app.staticTexts["scene-status-Alpha"].exists,
            "restored session auto-connected without user action"
        )

        reconnectButton.tap()

        let restoredStatus = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(restoredStatus.waitForExistence(timeout: 30), "manual reconnect must open the scene")
        XCTAssertTrue(
            waitUntil(restoredStatus, contains: "status:active", timeout: 60),
            "manual reconnect never reached active: \(label(of: restoredStatus))"
        )

        attachScreenshot(named: "task-14-restore")
    }

    /// A stale reconnect-required row can be dismissed permanently: the
    /// persisted snapshot is deleted (the saved connection survives), and
    /// the row never returns on later reloads or relaunches.
    func testRestorableRowDismissRemovesRowPermanently() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Restoration list flow runs on the phone form factor"
        )

        // Seed a restorable snapshot: connect Alpha, background (snapshot),
        // terminate.
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        let alphaStatus = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(
            alphaStatus.waitForExistence(timeout: 60),
            "Alpha scene never appeared on first launch"
        )
        XCTAssertTrue(
            waitUntil(alphaStatus, contains: "status:active", timeout: 45),
            "Alpha never connected on first launch"
        )

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        Thread.sleep(forTimeInterval: 3)
        app.terminate()

        // Relaunch keeping snapshots: the row must be listed and expose a
        // dismiss action alongside Reconnect.
        app.launchArguments = [
            "--uitest-pretrust-fixtures",
            "--uitest-sessions",
            "--uitest-expect-restore",
        ]
        app.launch()

        let dismissButton = app.buttons["restorable-dismiss-Alpha"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 20),
            "every restorable row must expose an accessible dismiss action"
        )
        XCTAssertTrue(app.buttons["restorable-reconnect-Alpha"].exists)

        dismissButton.tap()

        // The row leaves the list; the saved connection survives.
        let goneDeadline = Date().addingTimeInterval(10)
        while Date() < goneDeadline && dismissButton.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(dismissButton.exists, "dismissed row must leave the list")
        XCTAssertTrue(
            app.buttons["connection-Alpha"].waitForExistence(timeout: 10),
            "dismissal must never delete the saved connection"
        )

        // Relaunch again: the dismissed row must NOT return.
        app.terminate()
        app.launchArguments = [
            "--uitest-pretrust-fixtures",
            "--uitest-sessions",
            "--uitest-expect-restore",
        ]
        app.launch()

        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(
            app.buttons["restorable-reconnect-Alpha"].exists,
            "dismissed row must not return on relaunch"
        )
        XCTAssertFalse(app.buttons["restorable-dismiss-Alpha"].exists)
        XCTAssertTrue(
            app.buttons["connection-Alpha"].waitForExistence(timeout: 10),
            "the saved connection must still be listed after relaunch"
        )

        attachScreenshot(named: "restorable-dismiss-persisted")
    }

    // MARK: - Agent approval

    /// "Approve for this session": the first sign surfaces the sheet with
    /// the correct fingerprint/host/session, the second sign in the SAME
    /// session completes with no second sheet.
    func testAgentApprovalApproveForSessionSuppressesSecondPromptInSameSession() {
        let command = [
            agentSignCommand(data: "alpha-one"),
            agentSignCommand(data: "alpha-two"),
        ].joined(separator: " ; ")
        app.launchArguments = baseLaunchArguments(
            command: command,
            extra: ["--uitest-open-session", "Alpha"]
        )
        app.launch()

        let sheet = app.staticTexts["agent-approval-sheet"]
        let fingerprint = app.staticTexts["agent-fingerprint"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 90),
            "forwarded sign request never surfaced the approval sheet"
        )

        XCTAssertTrue(
            waitUntil(fingerprint, contains: Self.fixtureFingerprint, timeout: 5),
            "sheet fingerprint mismatch: \(label(of: fingerprint))"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["agent-host"], contains: "127.0.0.1", timeout: 5),
            "sheet must name the requesting host"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["agent-session"], contains: "Alpha", timeout: 5),
            "sheet must name the originating session"
        )

        attachScreenshot(named: "task-14-agent-prompt")

        app.buttons["agent-approve-session"].tap()

        // Sheet must dismiss; the first sign completes.
        let goneDeadline = Date().addingTimeInterval(15)
        while Date() < goneDeadline && sheet.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(sheet.exists, "approval sheet must dismiss after the decision")

        let alphaTail = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(
            waitUntil(alphaTail, contains: "signature:", timeout: 60),
            "approved sign never completed: \(label(of: alphaTail))"
        )

        // The second sign in the SAME session must complete without any
        // new prompt.
        let secondSignatureDeadline = Date().addingTimeInterval(60)
        while Date() < secondSignatureDeadline {
            let text = label(of: alphaTail)
            let occurrences = text.components(separatedBy: "signature:").count - 1
            if occurrences >= 2 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let finalText = label(of: alphaTail)
        let finalOccurrences = finalText.components(separatedBy: "signature:").count - 1
        XCTAssertGreaterThanOrEqual(
            finalOccurrences, 2,
            "second sign must complete after one session-scoped approval; tail: \(finalText)"
        )
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(
            sheet.exists,
            "no second approval sheet may appear within the same session"
        )
    }

    /// Deny fails the request (SSH_AGENT_FAILURE visible at the remote),
    /// and a NEW session prompts again — proving the approval cache is
    /// scoped to the originating session.
    func testAgentApprovalDenyFailsRequestAndNewSessionPromptsAgain() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Two-window scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            command: agentSignCommand(data: "deny-me"),
            extra: [
                "--uitest-open-session", "Alpha",
                "--uitest-open-session-after", "Beta:40",
            ]
        )
        app.launch()

        let sheet = app.staticTexts["agent-approval-sheet"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 90),
            "Alpha's forwarded sign request never surfaced the approval sheet"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["agent-session"], contains: "Alpha", timeout: 5),
            "first sheet must belong to Alpha"
        )

        app.buttons["agent-deny"].tap()
        let goneDeadline = Date().addingTimeInterval(15)
        while Date() < goneDeadline && sheet.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(sheet.exists, "sheet must dismiss after deny")

        let alphaTail = app.staticTexts["scene-tail-Alpha"]
        XCTAssertTrue(
            waitUntil(alphaTail, contains: "SSH_AGENT_FAILURE", timeout: 60),
            "denied sign must fail at the remote: \(label(of: alphaTail))"
        )

        // Beta (a NEW session, same key) must prompt again.
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 150),
            "a new session must surface its own approval prompt"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["agent-session"], contains: "Beta", timeout: 5),
            "second sheet must belong to Beta's session"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["agent-fingerprint"], contains: Self.fixtureFingerprint, timeout: 5),
            "Beta's sheet must show the same key fingerprint"
        )

        attachScreenshot(named: "task-14-agent-deny")

        app.buttons["agent-deny"].tap()
    }
}
