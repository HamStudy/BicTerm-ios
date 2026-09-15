import XCTest

/// The OSC 52 toast is the security guardrail of the remote-clipboard-write
/// feature: every approved write fires a "Copied N chars from <source>" banner
/// at the top of the session scene. Burst screenshots under the iOS 26.3
/// simulator cache the prior render tree for the nested-overlay path (NSLog
/// inside `SessionSceneView.body` confirmed the body re-evaluates with the
/// new value while the pixel pipeline lags), so the receipt for this feature
/// is the accessibility tree, not the pixel cache — XCUITest queries the AX
/// tree, which is rebuilt independently of the simulator's render cache.
///
/// Flow: seed the plain SSH herd fixture connections, connect to Herd Alpha
/// (fixture sshd on 12222, pretrusted), and let the `--uitest-osc52-trigger`
/// DEBUG seam feed an `OSC 52 ; c ; <base64>` sequence into the live terminal
/// right after the session-scene surface attaches. The production policy
/// approves the write (app foregrounded) and the scene must surface the toast
/// (`accessibilityIdentifier` = `osc52-toast-<scene>`, label = "Copied N
/// chars from <source>") within its ~3s auto-dismiss window. If this
/// assertion fails, the toast is genuinely absent from the AX hierarchy —
/// a rendering defect, not a screenshot artifact.
@MainActor
final class Osc52ToastUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testOsc52ToastAppearsOnApprovedWrite() {
        app.launchArguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-pretrust-fixtures",
            "--uitest-herd-e2e",
            "--uitest-osc52-trigger",
        ]
        app.launch()

        let row = app.buttons["connection-Herd-Alpha"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded herd connection must be listed")
        row.tap()

        // Terminal scene chrome proves the session scene is up; the
        // terminal surface attaches underneath it and the trigger fires.
        let sceneTitle = app.descendants(matching: .any)["scene-title-Herd-Alpha"]
        XCTAssertTrue(
            sceneTitle.waitForExistence(timeout: 30),
            "the Herd Alpha session scene must open before the trigger can fire"
        )

        // The toast auto-dismisses after ~3s; the trigger fires ~100ms
        // after surface attach. 10s covers attach + trigger + policy +
        // render + AX invalidation with margin.
        let toast = app.descendants(matching: .any)["osc52-toast-Herd-Alpha"]
        XCTAssertTrue(
            toast.waitForExistence(timeout: 10),
            "OSC 52 write must surface the security toast within its dismiss window — absence here means the toast is genuinely missing from the AX tree"
        )
        XCTAssertTrue(
            toast.label.hasPrefix("Copied "),
            "OSC 52 toast label must announce the write, got: '\(toast.label)'"
        )
        XCTAssertTrue(
            toast.label.contains("Herd Alpha"),
            "OSC 52 toast label must attribute the write to its source, got: '\(toast.label)'"
        )

        // Best-effort visual receipt — the simulator's overlay pixel cache
        // may lag the AX tree; if it surfaces the toast here the attachment
        // doubles as AX + visual proof.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "osc52-toast-ax"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
