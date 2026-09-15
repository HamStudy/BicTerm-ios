import Foundation
import Observation
import os

@MainActor
@Observable
final class KeyAvailabilityPreferences {
    private static let key = "keys.hardwareOfferedByDefault"
    private let defaults: UserDefaults
    private let backing: OSAllocatedUnfairLock<Bool>

    var hardwareOfferedByDefault: Bool {
        didSet {
            let enabled = hardwareOfferedByDefault
            backing.withLock { $0 = enabled }
            defaults.set(enabled, forKey: Self.key)
        }
    }

    /// Safe to retain in transports: captures only the lock, never this UI object.
    let hardwareKeysEnabledByDefault: @Sendable () -> Bool

    init(defaults: UserDefaults = .standard) {
        let initial = defaults.object(forKey: Self.key) as? Bool ?? true
        let backing = OSAllocatedUnfairLock(initialState: initial)
        self.defaults = defaults
        self.backing = backing
        self.hardwareOfferedByDefault = initial
        self.hardwareKeysEnabledByDefault = { backing.withLock { $0 } }
    }
}
