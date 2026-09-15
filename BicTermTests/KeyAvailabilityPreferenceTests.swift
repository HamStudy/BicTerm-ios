import BicTermCore
import Observation
import XCTest
import os
@testable import BicTerm

@MainActor
final class KeyAvailabilityPreferenceTests: XCTestCase {
    private let key = "keys.hardwareOfferedByDefault"

    func testAbsentPreferenceDefaultsToTrue() throws {
        let suite = "com.bicterm.tests.key-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: key))
        let preferences = KeyAvailabilityPreferences(defaults: defaults)
        XCTAssertTrue(preferences.hardwareOfferedByDefault)
        XCTAssertTrue(preferences.hardwareKeysEnabledByDefault())
    }

    func testToggleOffPersistsAcrossPreferenceRecreation() throws {
        let suite = "com.bicterm.tests.key-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyAvailabilityPreferences(defaults: defaults)
        preferences.hardwareOfferedByDefault = false
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

        let relaunched = KeyAvailabilityPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(relaunched.hardwareOfferedByDefault)
        XCTAssertFalse(relaunched.hardwareKeysEnabledByDefault())
        relaunched.hardwareOfferedByDefault = true
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
    }

    func testRetainedProviderReadsLiveBackingOffMainActor() async throws {
        let suite = "com.bicterm.tests.key-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyAvailabilityPreferences(defaults: defaults)
        let provider = preferences.hardwareKeysEnabledByDefault
        for enabled in [false, true, false] {
            preferences.hardwareOfferedByDefault = enabled
            XCTAssertEqual(provider(), enabled)
            defaults.set(!enabled, forKey: key)
            let backgroundValue = await Task.detached { provider() }.value
            XCTAssertEqual(backgroundValue, enabled, "Provider must read its backing, not UserDefaults")
        }
    }

    func testPreferenceChangeNotifiesObservationWithoutNavigation() throws {
        let suite = "com.bicterm.tests.key-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyAvailabilityPreferences(defaults: defaults)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = preferences.hardwareOfferedByDefault
        } onChange: {
            changed.withLock { $0 = true }
        }
        preferences.hardwareOfferedByDefault = false
        XCTAssertTrue(changed.withLock { $0 })
    }

    func testHardwarePreferenceFiltersInheritedPoolButNotExplicitSelection() throws {
        let suite = "com.bicterm.tests.key-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyAvailabilityPreferences(defaults: defaults)
        let provider = preferences.hardwareKeysEnabledByDefault
        let service = "com.bicterm.tests.key-preferences.se.\(UUID().uuidString)"
        let hardware = KeyMetadata(
            reference: UUID().uuidString, label: "Hardware", algorithm: .ecdsaP256,
            fingerprint: "SHA256:fixture", publicKeyBlob: Data([1, 2, 3]), requiresBiometry: true
        )
        try KeychainItemQuery.addItem(service: service, metadata: hardware)
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: hardware.reference) }
        let keys = try KeychainItemQuery.listItems(service: service).map(\.metadata)
        let resolver = KeyOfferResolver()
        preferences.hardwareOfferedByDefault = false
        XCTAssertEqual(resolver.resolve(KeyOfferRequest(
            offersKeys: true, customKeys: nil, hardwareKeysEnabledByDefault: provider()
        ), keys: keys), [])
        XCTAssertEqual(resolver.resolve(KeyOfferRequest(
            offersKeys: true, customKeys: [hardware.reference], hardwareKeysEnabledByDefault: provider()
        ), keys: keys), [hardware.reference])
        preferences.hardwareOfferedByDefault = true
        XCTAssertEqual(resolver.resolve(KeyOfferRequest(
            offersKeys: true, customKeys: nil, hardwareKeysEnabledByDefault: provider()
        ), keys: keys), [hardware.reference])
    }

    func testAppServicesSharesBothObservableInstances() {
        let firstWindow = AppServices.shared
        let settingsWindow = AppServices.shared
        XCTAssertTrue(firstWindow.keyAvailabilityPreferences === settingsWindow.keyAvailabilityPreferences)
        XCTAssertTrue(firstWindow.keyStore === settingsWindow.keyStore)
    }
}
