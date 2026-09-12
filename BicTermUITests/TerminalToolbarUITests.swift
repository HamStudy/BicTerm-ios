import UIKit
import XCTest

/// Terminal accessory toolbar (esc/ctrl/tab/arrows strip): the toggle lives
/// in the scene chrome's top-right session menu (ellipsis) and persists an
/// explicit choice, and a visible toolbar participates in layout — the
/// terminal shrinks by exactly the strip's height instead of being overlaid.
///
/// The hardware-keyboard heuristic only supplies the default; these tests
/// drive explicit toggles so they pass on any simulator regardless of its
/// hardware-keyboard state. Launches clear the persisted choice unless
/// `--uitest-keep-toolbar-pref` is passed (relaunch persistence test).
@MainActor
final class TerminalToolbarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func launch(keepToolbarPref: Bool = false) {
        var arguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
        ]
        if keepToolbarPref {
            arguments.append("--uitest-keep-toolbar-pref")
        }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 60),
            "scene chrome never appeared"
        )
    }

    private var menuButton: XCUIElement {
        app.buttons["scene-menu"].firstMatch
    }

    private var toggleButton: XCUIElement {
        app.buttons["terminal-toolbar-toggle"]
    }

    /// The toolbar toggle lives inside the scene's session menu: open the
    /// menu, then tap the item (the menu closes on selection).
    private func tapToolbarToggleInMenu() {
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "session menu never appeared")
        menuButton.tap()
        XCTAssertTrue(
            toggleButton.waitForExistence(timeout: 5),
            "toolbar toggle missing from the session menu"
        )
        toggleButton.tap()
    }

    private var accessory: XCUIElement {
        app.descendants(matching: .any)["terminal-accessory"]
    }

    private var terminal: XCUIElement {
        app.descendants(matching: .any)["terminalView"]
    }

    /// Matches SwiftTerm's accessory heights (setupAccessoryView) and the
    /// host view's strip: 36 on phone, 48 otherwise.
    private var stripHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 36 : 48
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    /// The toggle lives in the scene chrome's session menu (ellipsis), the
    /// only top-right control besides Close.
    func testToggleButtonPresentInSceneChrome() {
        launch()
        XCTAssertTrue(menuButton.exists)
        XCTAssertTrue(menuButton.isHittable)
        XCTAssertFalse(
            toggleButton.exists,
            "the toolbar toggle must live inside the menu, not the chrome"
        )
        menuButton.tap()
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
        XCTAssertTrue(toggleButton.isHittable)
    }

    /// Toggling shows/hides the strip, and the terminal frame shrinks or
    /// grows by exactly the strip height — the toolbar is a layout
    /// participant and can never cover the terminal's bottom row.
    func testToggleShowsAccessoryAndTerminalShrinksInLayout() {
        launch()

        let wasVisible = accessory.exists
        let heightBefore = terminal.frame.height

        tapToolbarToggleInMenu()

        if wasVisible {
            XCTAssertTrue(
                accessory.waitForNonExistence(timeout: 10),
                "toolbar must disappear after the toggle"
            )
            XCTAssertEqual(
                terminal.frame.height - heightBefore, stripHeight, accuracy: 2,
                "hiding the toolbar must return the strip's height to the terminal"
            )
        } else {
            XCTAssertTrue(
                accessory.waitForExistence(timeout: 10),
                "toolbar must appear after the toggle"
            )
            attachScreenshot(named: "toolbar-visible")
            XCTAssertEqual(
                heightBefore - terminal.frame.height, stripHeight, accuracy: 2,
                "showing the toolbar must shrink the terminal by the strip height — no overlay"
            )
            tapToolbarToggleInMenu()
            XCTAssertTrue(
                accessory.waitForNonExistence(timeout: 10),
                "second toggle must hide the toolbar again"
            )
            attachScreenshot(named: "toolbar-hidden")
        }
    }

    /// The explicit choice is persisted: visible across a relaunch when
    /// toggled on, hidden across a relaunch when toggled off.
    func testExplicitChoicePersistsAcrossRelaunch() {
        launch()

        // Establish explicit ON regardless of the heuristic default.
        if !accessory.exists {
            tapToolbarToggleInMenu()
        }
        XCTAssertTrue(accessory.waitForExistence(timeout: 10))

        app.terminate()
        launch(keepToolbarPref: true)
        XCTAssertTrue(
            accessory.waitForExistence(timeout: 10),
            "explicit ON must survive a relaunch"
        )

        // Establish explicit OFF.
        tapToolbarToggleInMenu()
        XCTAssertTrue(accessory.waitForNonExistence(timeout: 10))

        app.terminate()
        launch(keepToolbarPref: true)
        XCTAssertTrue(menuButton.waitForExistence(timeout: 60))
        XCTAssertFalse(
            accessory.waitForExistence(timeout: 5),
            "explicit OFF must survive a relaunch"
        )
    }
}
