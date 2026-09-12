import XCTest
@testable import BicTerm

/// TerminalFontSettings / TerminalFontModel: clamping to 9...32, 0.5pt
/// quantization, persistence round-trip, reset-to-default, and the
/// `onApplied` hook that drives live re-fonting of cached surfaces.
@MainActor
final class TerminalFontSettingsTests: XCTestCase {
    private func ephemeralDefaults() throws -> UserDefaults {
        let name = "font-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Defaults and normalization

    /// An absent key reads as the 14pt default.
    func testDefaultSizeWhenUnset() throws {
        let settings = TerminalFontSettings(defaults: try ephemeralDefaults())
        XCTAssertEqual(settings.size, TerminalFontSettings.defaultSize)
        XCTAssertEqual(settings.size, 14)
    }

    /// The pinch/slider math: values snap to the nearest 0.5pt step.
    func testQuantizesToHalfPointSteps() {
        XCTAssertEqual(TerminalFontSettings.normalize(14.24), 14.0)
        XCTAssertEqual(TerminalFontSettings.normalize(14.26), 14.5)
        XCTAssertEqual(TerminalFontSettings.normalize(14.25), 14.5, "halves round away from zero")
        XCTAssertEqual(TerminalFontSettings.normalize(13.75), 14.0)
        XCTAssertEqual(TerminalFontSettings.normalize(14.0), 14.0, "already-quantized values are stable")
    }

    /// Out-of-range sizes clamp into 9...32.
    func testClampsToRange() {
        XCTAssertEqual(TerminalFontSettings.normalize(2), 9)
        XCTAssertEqual(TerminalFontSettings.normalize(8.9), 9)
        XCTAssertEqual(TerminalFontSettings.normalize(100), 32)
        XCTAssertEqual(TerminalFontSettings.normalize(32.4), 32)
    }

    /// A non-finite gesture scale can never poison the pref.
    func testNonFiniteFallsBackToDefault() {
        XCTAssertEqual(TerminalFontSettings.normalize(.infinity), 14)
        XCTAssertEqual(TerminalFontSettings.normalize(.nan), 14)
    }

    // MARK: - Persistence

    /// A written size survives a fresh settings instance over the same
    /// suite (launch persistence), normalized on the way in.
    func testSetSizePersistsAcrossInstances() throws {
        let defaults = try ephemeralDefaults()
        TerminalFontSettings(defaults: defaults).setSize(17.3)

        let reloaded = TerminalFontSettings(defaults: defaults)
        XCTAssertEqual(reloaded.size, 17.5)
    }

    /// Reset removes the stored key: the next read returns the default.
    func testResetReturnsToDefault() throws {
        let defaults = try ephemeralDefaults()
        let settings = TerminalFontSettings(defaults: defaults)
        settings.setSize(22)
        XCTAssertEqual(settings.size, 22)

        settings.reset()
        XCTAssertEqual(settings.size, 14)
        XCTAssertEqual(TerminalFontSettings(defaults: defaults).size, 14)
    }

    /// A stale/foreign value already in defaults (older build, other tool)
    /// is normalized on READ, never trusted raw.
    func testStaleStoredValueIsNormalizedOnRead() throws {
        let defaults = try ephemeralDefaults()
        defaults.set(41.7, forKey: "bicterm.terminal.fontSize")
        XCTAssertEqual(TerminalFontSettings(defaults: defaults).size, 32)
    }

    // MARK: - Model

    /// setSize publishes the normalized value, persists it, and notifies
    /// the cache hook exactly once.
    func testModelSetSizePublishesPersistsAndNotifies() throws {
        let defaults = try ephemeralDefaults()
        let model = TerminalFontModel(settings: TerminalFontSettings(defaults: defaults))
        var applied: [Double] = []
        model.onApplied = { applied.append($0) }

        model.setSize(18.2)
        XCTAssertEqual(model.size, 18.0)
        XCTAssertEqual(applied, [18.0])
        XCTAssertEqual(TerminalFontSettings(defaults: defaults).size, 18.0)
    }

    /// Inter-step pinch events (or a slider re-emitting the current value)
    /// must not re-notify: no quantization change, no cache churn.
    func testModelSetSizeNoChangeDoesNotNotify() throws {
        let model = TerminalFontModel(settings: TerminalFontSettings(defaults: try ephemeralDefaults()))
        var applied: [Double] = []
        model.onApplied = { applied.append($0) }

        model.setSize(14.2)
        XCTAssertEqual(model.size, 14)
        XCTAssertTrue(applied.isEmpty, "same normalized size must be a no-op")
    }

    /// The model reads the persisted size at init (relaunch state).
    func testModelInitReadsPersistedSize() throws {
        let defaults = try ephemeralDefaults()
        TerminalFontSettings(defaults: defaults).setSize(26)
        XCTAssertEqual(TerminalFontModel(settings: TerminalFontSettings(defaults: defaults)).size, 26)
    }

    /// Reset restores the default and notifies so surfaces re-font back.
    func testModelResetNotifiesAndClears() throws {
        let defaults = try ephemeralDefaults()
        let settings = TerminalFontSettings(defaults: defaults)
        let model = TerminalFontModel(settings: settings)
        model.setSize(20)

        var applied: [Double] = []
        model.onApplied = { applied.append($0) }
        model.reset()

        XCTAssertEqual(model.size, 14)
        XCTAssertEqual(applied, [14])
        XCTAssertEqual(settings.size, 14, "reset must clear the stored key")

        // Resetting at default is a no-op (no redundant re-font).
        model.reset()
        XCTAssertEqual(applied, [14])
    }
}
