import XCTest

/// Settings → Terminal → Keep Screen On: the toggle reflects the persisted
/// preference (OFF by default under the DEBUG launch control's reset),
/// toggling ON persists across a relaunch with `--uitest-keep-screen-on`
/// (the model re-applies the pref to the UIKit idle timer at init — that
/// side effect is asserted at model level in KeepAwakeTests; this suite
/// asserts the observable state: the toggle), and toggling OFF restores
/// the default.
///
/// Launches pass `--uitest-sessions` so the keep-awake launch control
/// resets the pref to OFF unless `--uitest-keep-screen-on` keeps it; no
/// fixture connections are opened.
@MainActor
final class KeepAwakeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        super.tearDown()
    }

    private func launch(keepingScreenOnPref: Bool = false) {
        var arguments = ["--uitest-sessions"]
        if keepingScreenOnPref {
            arguments.append("--uitest-keep-screen-on")
        }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(
            app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 60),
            "connection list never appeared"
        )
    }

    private var keepAwakeToggle: XCUIElement {
        app.switches["settings-keep-screen-on"].firstMatch
    }

    private func openSettings() {
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
            "Settings never appeared"
        )
        XCTAssertTrue(
            keepAwakeToggle.waitForExistence(timeout: 10),
            "Keep Screen On toggle missing from the Terminal section"
        )
    }

    /// Same trailing-switch tap as the editor suites' setToggle: the
    /// element spans the whole row, so a center tap hits the label —
    /// the switch control sits at the trailing edge.
    private func setKeepScreenOn(_ on: Bool) {
        func isOn() -> Bool {
            (keepAwakeToggle.value as? String ?? "").lowercased() == "1"
        }
        var taps = 0
        while isOn() != on {
            guard taps < 6 else {
                XCTFail("Keep Screen On toggle never reached \(on)")
                return
            }
            keepAwakeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            taps += 1
        }
    }

    /// Default OFF → toggle ON → relaunch preserving → still ON (the
    /// model restored the persisted pref) → toggle OFF restores the
    /// default.
    func testToggleOnPersistsAcrossRelaunchAndOffRestores() {
        launch()
        openSettings()
        XCTAssertEqual(
            keepAwakeToggle.value as? String, "0",
            "Keep Screen On must be OFF at the default"
        )

        setKeepScreenOn(true)

        app.terminate()
        launch(keepingScreenOnPref: true)
        openSettings()
        XCTAssertEqual(
            keepAwakeToggle.value as? String, "1",
            "ON must survive a relaunch when the pref is kept"
        )

        setKeepScreenOn(false)
        XCTAssertEqual(
            keepAwakeToggle.value as? String, "0",
            "toggling OFF must restore the default"
        )
    }

    /// A relaunch WITHOUT the keep flag resets the pref through the
    /// DEBUG launch control: a persisted ON never leaks into the next
    /// test's launch.
    func testRelaunchWithoutKeepFlagResetsToOff() {
        launch()
        openSettings()
        setKeepScreenOn(true)

        app.terminate()
        launch()
        openSettings()
        XCTAssertEqual(
            keepAwakeToggle.value as? String, "0",
            "a launch without --uitest-keep-screen-on must reset the pref to OFF"
        )
    }
}
