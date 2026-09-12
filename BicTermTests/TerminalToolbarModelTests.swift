import XCTest
@testable import BicTerm

/// TerminalToolbarModel: hardware-keyboard heuristic supplies the default,
/// an explicit toggle persists (UserDefaults via TerminalToolbarSettings)
/// and wins over the heuristic until cleared.
@MainActor
final class TerminalToolbarModelTests: XCTestCase {
    private func ephemeralDefaults() throws -> UserDefaults {
        let name = "toolbar-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeModel(
        defaults: UserDefaults,
        hardwareKeyboardAttached: Bool
    ) -> TerminalToolbarModel {
        TerminalToolbarModel(
            settings: TerminalToolbarSettings(defaults: defaults),
            hardwareKeyboardAttached: hardwareKeyboardAttached
        )
    }

    /// iPad + hardware keyboard (GCKeyboard.coalesced != nil): the toolbar
    /// starts HIDDEN — hardware keys already cover esc/ctrl/tab/arrows.
    func testDefaultsHiddenWhenHardwareKeyboardAttached() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: true)
        XCTAssertFalse(model.isVisible)
    }

    /// On-screen keyboard only: the toolbar starts SHOWN — the strip is the
    /// user's esc/ctrl/tab access.
    func testDefaultsShownWithoutHardwareKeyboard() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: false)
        XCTAssertTrue(model.isVisible)
    }

    /// The explicit choice survives a fresh model over the same defaults —
    /// here explicit ON beats a heuristic that would hide.
    func testToggleOnPersistsAcrossInstances() throws {
        let defaults = try ephemeralDefaults()
        let model = makeModel(defaults: defaults, hardwareKeyboardAttached: true)
        model.toggle()
        XCTAssertTrue(model.isVisible)

        let reloaded = makeModel(defaults: defaults, hardwareKeyboardAttached: true)
        XCTAssertTrue(reloaded.isVisible)
    }

    /// Explicit OFF beats a heuristic that would show (on-screen keyboard).
    func testToggleOffPersistsAcrossInstances() throws {
        let defaults = try ephemeralDefaults()
        let model = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        model.toggle()
        XCTAssertFalse(model.isVisible)

        let reloaded = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        XCTAssertFalse(reloaded.isVisible)
    }

    /// Clearing the explicit choice removes the stored key and returns to
    /// the heuristic default.
    func testClearExplicitChoiceReturnsToHeuristic() throws {
        let defaults = try ephemeralDefaults()
        let settings = TerminalToolbarSettings(defaults: defaults)
        let model = makeModel(defaults: defaults, hardwareKeyboardAttached: true)
        model.toggle()
        XCTAssertNotNil(settings.explicitVisibility)

        model.clearExplicitChoice()
        XCTAssertNil(settings.explicitVisibility)
        XCTAssertFalse(model.isVisible)
    }
}
