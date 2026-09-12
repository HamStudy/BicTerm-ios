import SwiftUI
import XCTest
@testable import BicTerm

/// ThemeSettings / ThemeModel: System default, Dark/Light persistence
/// round-trip, reset, invalid/foreign stored values, the
/// `colorSchemeOverride` mapping, and the model's publish behavior.
@MainActor
final class ThemeSettingsTests: XCTestCase {
    private func ephemeralDefaults() throws -> UserDefaults {
        let name = "theme-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Defaults

    /// An absent key reads as System (no explicit choice).
    func testDefaultIsSystemWhenUnset() throws {
        let settings = ThemeSettings(defaults: try ephemeralDefaults())
        XCTAssertEqual(settings.preference, .system)
    }

    /// System maps to NO override: scenes follow the device appearance.
    func testColorSchemeOverrideMapping() {
        XCTAssertNil(AppearancePreference.system.colorSchemeOverride)
        XCTAssertEqual(AppearancePreference.dark.colorSchemeOverride, .dark)
        XCTAssertEqual(AppearancePreference.light.colorSchemeOverride, .light)
    }

    // MARK: - Persistence

    /// A written preference survives a fresh settings instance over the
    /// same suite (launch persistence).
    func testSetPreferencePersistsAcrossInstances() throws {
        let defaults = try ephemeralDefaults()
        ThemeSettings(defaults: defaults).setPreference(.dark)
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .dark)

        ThemeSettings(defaults: defaults).setPreference(.light)
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .light)
    }

    /// Selecting System REMOVES the stored key: absent means no explicit
    /// choice, so the next read (and any relaunch) returns System.
    func testSystemSelectionClearsStoredValue() throws {
        let defaults = try ephemeralDefaults()
        let settings = ThemeSettings(defaults: defaults)
        settings.setPreference(.dark)
        XCTAssertEqual(settings.preference, .dark)

        settings.setPreference(.system)
        XCTAssertEqual(settings.preference, .system)
        XCTAssertNil(defaults.string(forKey: "bicterm.appearance.theme"))
    }

    /// Reset removes the stored key: the next read returns System.
    func testResetReturnsToSystem() throws {
        let defaults = try ephemeralDefaults()
        let settings = ThemeSettings(defaults: defaults)
        settings.setPreference(.light)
        XCTAssertEqual(settings.preference, .light)

        settings.reset()
        XCTAssertEqual(settings.preference, .system)
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .system)
    }

    /// An unknown raw value already in defaults (older build, other tool)
    /// falls back to System, never trusted raw.
    func testInvalidStoredValueFallsBackToSystem() throws {
        let defaults = try ephemeralDefaults()
        defaults.set("solarized", forKey: "bicterm.appearance.theme")
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .system)
    }

    /// A non-string foreign value also falls back to System.
    func testNonStringStoredValueFallsBackToSystem() throws {
        let defaults = try ephemeralDefaults()
        defaults.set(42, forKey: "bicterm.appearance.theme")
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .system)
    }

    // MARK: - Model

    /// The model reads the persisted preference at init (relaunch state).
    func testModelInitReadsPersistedPreference() throws {
        let defaults = try ephemeralDefaults()
        ThemeSettings(defaults: defaults).setPreference(.light)
        let model = ThemeModel(settings: ThemeSettings(defaults: defaults))
        XCTAssertEqual(model.preference, .light)
        XCTAssertEqual(model.colorSchemeOverride, .light)
    }

    /// setPreference publishes the new value and persists it.
    func testModelSetPreferencePublishesAndPersists() throws {
        let defaults = try ephemeralDefaults()
        let model = ThemeModel(settings: ThemeSettings(defaults: defaults))
        XCTAssertEqual(model.preference, .system)
        XCTAssertNil(model.colorSchemeOverride)

        model.setPreference(.dark)
        XCTAssertEqual(model.preference, .dark)
        XCTAssertEqual(model.colorSchemeOverride, .dark)
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .dark)
    }

    /// Re-selecting the current preference is a no-op: the stored key
    /// state is untouched (System must keep the key absent).
    func testModelSetPreferenceNoChangeLeavesStorageUntouched() throws {
        let defaults = try ephemeralDefaults()
        let model = ThemeModel(settings: ThemeSettings(defaults: defaults))

        model.setPreference(.system)
        XCTAssertEqual(model.preference, .system)
        XCTAssertNil(defaults.string(forKey: "bicterm.appearance.theme"))
    }

    /// Reset publishes System and clears the persisted choice.
    func testModelResetPublishesSystemAndClears() throws {
        let defaults = try ephemeralDefaults()
        let model = ThemeModel(settings: ThemeSettings(defaults: defaults))
        model.setPreference(.light)
        XCTAssertEqual(model.preference, .light)

        model.reset()
        XCTAssertEqual(model.preference, .system)
        XCTAssertNil(model.colorSchemeOverride)
        XCTAssertEqual(ThemeSettings(defaults: defaults).preference, .system)
    }
}
