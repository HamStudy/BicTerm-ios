import XCTest

/// Settings → Appearance → Font Size: the row navigates to a live editor —
/// slider bound to the shared terminal font-size pref, a live value label,
/// a monospace preview, and Reset to Default (disabled at the 14pt default,
/// enabled after a change, restoring 14pt on tap).
///
/// Settings → Appearance → Theme: the row shows the live appearance
/// preference (System by default) and navigates to a picker detail offering
/// System/Dark/Light; a selection updates the row, persists across a
/// relaunch with `--uitest-keep-theme-pref`, and System restores.
///
/// Launches pass `--uitest-sessions` so the driver resets the persisted
/// font size and theme to their defaults; no fixture connections are opened.
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

    private func launch(keepThemePref: Bool = false) {
        var arguments = ["--uitest-sessions"]
        if keepThemePref {
            arguments.append("--uitest-keep-theme-pref")
        }
        app.launchArguments = arguments
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

    private var themeRow: XCUIElement { app.buttons["settings-theme"].firstMatch }
    private var themePicker: XCUIElement { app.descendants(matching: .any)["theme-picker"].firstMatch }

    private func openSettings() {
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
            "Settings never appeared"
        )
    }

    private func themeRowValue(_ value: String) -> XCUIElement {
        themeRow.staticTexts[value]
    }

    private func openFontSizeDetail() {
        openSettings()
        let row = app.buttons["settings-font-size"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Font Size row missing from Appearance")
        row.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "Font Size detail never appeared")
    }

    private func openThemeDetail() {
        openSettings()
        XCTAssertTrue(themeRow.waitForExistence(timeout: 10), "Theme row missing from Appearance")
        themeRow.tap()
        XCTAssertTrue(themePicker.waitForExistence(timeout: 10), "Theme detail never appeared")
    }

    private func selectThemeOption(_ label: String) {
        let option = app.buttons["theme-option-\(label.lowercased())"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(label) option missing from the theme picker")
        option.tap()
    }

    private func leaveThemeDetail() {
        app.navigationBars["Theme"].buttons["Settings"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
            "never returned to Settings"
        )
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

    // MARK: - Theme (Appearance preference)

    /// The Theme row shows the current preference — System by default — and
    /// the detail offers exactly System/Dark/Light with the selection
    /// checkmarked.
    func testThemeRowShowsSystemByDefaultAndPickerOffersThreeOptions() {
        launch()
        openSettings()
        XCTAssertTrue(themeRow.waitForExistence(timeout: 10), "Theme row missing from Appearance")
        XCTAssertTrue(
            themeRowValue("System").exists,
            "Theme row must show System at the default"
        )

        themeRow.tap()
        XCTAssertTrue(themePicker.waitForExistence(timeout: 10), "Theme detail never appeared")
        for label in ["System", "Dark", "Light"] {
            XCTAssertTrue(
                app.buttons["theme-option-\(label.lowercased())"].firstMatch.waitForExistence(timeout: 5),
                "\(label) option missing from the theme picker"
            )
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["theme-selected-system"].firstMatch.exists,
            "System must be the checkmarked selection at the default"
        )
    }

    /// Selecting Dark updates the row and persists across a relaunch with
    /// the pref kept; selecting System again restores the default.
    func testThemeSelectionUpdatesRowPersistsAcrossRelaunchAndSystemRestores() {
        launch()
        openThemeDetail()
        selectThemeOption("Dark")

        leaveThemeDetail()
        XCTAssertTrue(
            themeRowValue("Dark").waitForExistence(timeout: 5),
            "Theme row must show Dark after selection"
        )

        app.terminate()
        launch(keepThemePref: true)
        openSettings()
        XCTAssertTrue(themeRow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            themeRowValue("Dark").waitForExistence(timeout: 5),
            "Dark must survive a relaunch when the pref is kept"
        )

        themeRow.tap()
        XCTAssertTrue(themePicker.waitForExistence(timeout: 10))
        selectThemeOption("System")
        leaveThemeDetail()
        XCTAssertTrue(
            themeRowValue("System").waitForExistence(timeout: 5),
            "selecting System must restore the default"
        )
    }
}
