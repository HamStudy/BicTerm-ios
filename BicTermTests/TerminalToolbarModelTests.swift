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

    /// Sticky keyboard dismissal: hide flips the state, show clears it,
    /// and both are idempotent.
    func testKeyboardHiddenHideAndShow() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: false)

        XCTAssertFalse(model.keyboardHidden)
        model.hideSoftwareKeyboard()
        XCTAssertTrue(model.keyboardHidden)
        model.hideSoftwareKeyboard()
        XCTAssertTrue(model.keyboardHidden)

        model.showSoftwareKeyboard()
        XCTAssertFalse(model.keyboardHidden)
        model.showSoftwareKeyboard()
        XCTAssertFalse(model.keyboardHidden)
    }

    /// The model's hide is unconditional — the dismiss gate (software
    /// keyboard actually on screen) lives in the host view, because
    /// GCKeyboard is a false positive on the simulator (the Mac keyboard
    /// bridges as a controller while the software keyboard stays visible).
    func testKeyboardHideIndependentOfHardwareKeyboardFlag() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: true)

        model.hideSoftwareKeyboard()
        XCTAssertTrue(model.keyboardHidden)
    }

    /// The sticky state is transient: a fresh model (fresh launch) always
    /// starts with the keyboard installed.
    func testKeyboardHiddenNotPersisted() throws {
        let defaults = try ephemeralDefaults()
        let model = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        model.hideSoftwareKeyboard()
        XCTAssertTrue(model.keyboardHidden)

        let relaunched = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        XCTAssertFalse(relaunched.keyboardHidden)
    }

    // MARK: - Input mode (fork hunk 17)

    /// The function-keys toggle flips between the system keyboard and
    /// the panel, and from `.hidden` summons the panel directly.
    func testFunctionKeysToggleTransitions() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: false)

        XCTAssertEqual(model.inputMode, .keyboard)
        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .functionKeys)
        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .keyboard)

        model.hideSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .hidden)
        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .functionKeys, "the toggle from hidden must summon the panel (the panel IS the input surface)")
        XCTAssertFalse(model.keyboardHidden)
    }

    /// The dismiss control lands in `.hidden` from either surface; a
    /// terminal tap returns to the system keyboard.
    func testDismissAndTapReEnableTransitions() throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: false)

        model.hideSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .hidden)
        model.showSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .keyboard)

        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .functionKeys)
        model.hideSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .hidden, "dismissal from the panel must land in hidden")
        model.showSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .keyboard, "a terminal tap must return the system keyboard, not the panel")
    }

    /// The mode is transient like the sticky hide: a fresh launch always
    /// starts with the system keyboard.
    func testInputModeNotPersisted() throws {
        let defaults = try ephemeralDefaults()
        let model = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .functionKeys)

        let relaunched = makeModel(defaults: defaults, hardwareKeyboardAttached: false)
        XCTAssertEqual(relaunched.inputMode, .keyboard)
    }

    /// A hardware keyboard attaching at runtime ends the sticky hide (the
    /// K1 blocker would break hardware-key delivery) but deliberately
    /// NOT the function-key panel: it is an explicit user mode, hardware
    /// keys deliver in parallel, and the user dismisses it through the
    /// same toggle.
    func testHardwareAttachExitsHiddenButKeepsFunctionKeys() async throws {
        let model = makeModel(defaults: try ephemeralDefaults(), hardwareKeyboardAttached: false)

        model.hideSoftwareKeyboard()
        XCTAssertEqual(model.inputMode, .hidden)

        NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
        await waitUntil { !model.isVisible }  // proves keyboardAttachmentChanged ran
        XCTAssertEqual(model.inputMode, .keyboard, "hardware attach must end the sticky hide")

        model.toggleFunctionKeys()
        XCTAssertEqual(model.inputMode, .functionKeys)
        NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
        await waitUntil { !model.isVisible }
        XCTAssertEqual(model.inputMode, .functionKeys, "hardware attach must not force-exit the function-key panel")
    }

    /// The observer handler hops through `Task { @MainActor }`; yield to
    /// the main actor until the condition flips (bounded).
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }
}
