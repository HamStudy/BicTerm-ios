import UIKit
import XCTest
@testable import BicTerm

/// KeepAwakeSettings / KeepAwakeModel: OFF by default, persistence
/// round-trip, reset, foreign-value fallback, and the UIKit side effect —
/// `UIApplication.shared.isIdleTimerDisabled` mirrors the preference at
/// init, on every mutation, and is ALWAYS restored when OFF.
@MainActor
final class KeepAwakeTests: XCTestCase {
    private func ephemeralDefaults() throws -> UserDefaults {
        let name = "keep-awake-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    override func setUp() {
        super.setUp()
        // The applied side effect is process-global UIKit state; start
        // every test from the idle timer ENABLED so assertions observe
        // only this test's model operations.
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Settings

    /// An absent key reads as OFF (fresh launch, never chosen).
    func testDefaultIsOffWhenUnset() throws {
        let settings = KeepAwakeSettings(defaults: try ephemeralDefaults())
        XCTAssertFalse(settings.keepScreenOn)
    }

    /// A written choice survives a fresh settings instance over the same
    /// suite (launch persistence).
    func testSetPersistsAcrossInstances() throws {
        let defaults = try ephemeralDefaults()
        KeepAwakeSettings(defaults: defaults).setKeepScreenOn(true)
        XCTAssertTrue(KeepAwakeSettings(defaults: defaults).keepScreenOn)

        KeepAwakeSettings(defaults: defaults).setKeepScreenOn(false)
        XCTAssertFalse(KeepAwakeSettings(defaults: defaults).keepScreenOn)
    }

    /// Reset removes the stored key: the next read returns OFF.
    func testResetClearsStoredValue() throws {
        let defaults = try ephemeralDefaults()
        let settings = KeepAwakeSettings(defaults: defaults)
        settings.setKeepScreenOn(true)

        settings.reset()
        XCTAssertFalse(KeepAwakeSettings(defaults: defaults).keepScreenOn)
        XCTAssertNil(defaults.object(forKey: "bicterm.terminal.keepScreenOn"))
    }

    /// A non-Bool foreign value already in defaults falls back to OFF,
    /// never trusted raw.
    func testForeignStoredValueFallsBackToOff() throws {
        let defaults = try ephemeralDefaults()
        defaults.set(42, forKey: "bicterm.terminal.keepScreenOn")
        XCTAssertFalse(KeepAwakeSettings(defaults: defaults).keepScreenOn)
    }

    // MARK: - Model (idle-timer application)

    /// Fresh launch with the pref unset: constructing the model never
    /// leaves the idle timer disabled.
    func testModelInitWithUnsetPrefNeverDisablesIdleTimer() throws {
        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: try ephemeralDefaults()))
        XCTAssertFalse(model.keepScreenOn)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Persisted relaunch restore: a model constructed over a stored
    /// `true` (relaunch) reads it back and disables the idle timer at
    /// init.
    func testModelInitAppliesPersistedPreferenceToIdleTimer() throws {
        let defaults = try ephemeralDefaults()
        KeepAwakeSettings(defaults: defaults).setKeepScreenOn(true)

        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: defaults))
        XCTAssertTrue(model.keepScreenOn)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Toggling ON disables the idle timer and persists the choice.
    func testSetTrueDisablesIdleTimerAndPersists() throws {
        let defaults = try ephemeralDefaults()
        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: defaults))

        model.setKeepScreenOn(true)
        XCTAssertTrue(model.keepScreenOn)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertTrue(KeepAwakeSettings(defaults: defaults).keepScreenOn)
    }

    /// Turning it OFF always restores the idle timer — even straight
    /// after a launch that restored it ON.
    func testSetFalseAlwaysRestoresIdleTimer() throws {
        let defaults = try ephemeralDefaults()
        KeepAwakeSettings(defaults: defaults).setKeepScreenOn(true)
        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: defaults))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        model.setKeepScreenOn(false)
        XCTAssertFalse(model.keepScreenOn)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertFalse(KeepAwakeSettings(defaults: defaults).keepScreenOn)
    }

    /// Re-setting the current value is a no-op: state and storage
    /// untouched.
    func testModelSetNoChangeLeavesStateUntouched() throws {
        let defaults = try ephemeralDefaults()
        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: defaults))

        model.setKeepScreenOn(false)
        XCTAssertFalse(model.keepScreenOn)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertNil(defaults.object(forKey: "bicterm.terminal.keepScreenOn"))
    }

    /// Reset publishes OFF, restores the idle timer, and clears the
    /// persisted choice.
    func testModelResetRestoresIdleTimerAndClearsStorage() throws {
        let defaults = try ephemeralDefaults()
        let model = KeepAwakeModel(settings: KeepAwakeSettings(defaults: defaults))
        model.setKeepScreenOn(true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        model.reset()
        XCTAssertFalse(model.keepScreenOn)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertNil(defaults.object(forKey: "bicterm.terminal.keepScreenOn"))
    }
}
