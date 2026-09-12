import XCTest

/// Settings → Appearance → Font Size: the row navigates to a live editor —
/// slider bound to the shared terminal font-size pref, a live value label,
/// a monospace preview, and Reset to Default (disabled at the 14pt default,
/// enabled after a change, restoring 14pt on tap).
///
/// Launches pass `--uitest-sessions` so the driver resets the persisted
/// font size to the default; no fixture connections are opened.
@MainActor
final class SettingsUITests: XCTestCase {
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

    private func launch() {
        app.launchArguments = ["--uitest-sessions"]
        app.launch()
        XCTAssertTrue(
            app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 60),
            "connection list never appeared"
        )
    }

    private var slider: XCUIElement { app.sliders["font-size-slider"] }
    private var valueLabel: XCUIElement { app.staticTexts["font-size-value"] }
    private var preview: XCUIElement { app.staticTexts["font-size-preview"] }
    private var resetButton: XCUIElement { app.buttons["font-size-reset"].firstMatch }

    private func openFontSizeDetail() {
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
            "Settings never appeared"
        )
        let row = app.buttons["settings-font-size"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Font Size row missing from Appearance")
        row.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "Font Size detail never appeared")
    }

    /// Row → detail: slider, live value, and preview exist; Reset is
    /// disabled at the default size.
    func testFontSizeDetailShowsSliderValueAndPreviewWithResetDisabledAtDefault() {
        launch()
        openFontSizeDetail()

        XCTAssertTrue(slider.exists)
        XCTAssertEqual(valueLabel.label, "14 pt")
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(resetButton.isEnabled, "Reset must be disabled at the 14pt default")
    }

    /// Moving the slider updates the live value and enables Reset; tapping
    /// Reset restores 14pt and disables it again.
    func testSliderChangeEnablesResetAndResetRestoresDefault() {
        launch()
        openFontSizeDetail()

        slider.adjust(toNormalizedSliderPosition: 1.0)
        XCTAssertEqual(valueLabel.label, "32 pt", "slider at maximum must read 32 pt")
        XCTAssertTrue(resetButton.isEnabled, "Reset must enable once the size differs from default")

        resetButton.tap()
        XCTAssertEqual(valueLabel.label, "14 pt", "Reset must restore the 14pt default")
        XCTAssertFalse(resetButton.isEnabled, "Reset must disable again at the default")
    }
}
