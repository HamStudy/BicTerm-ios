import SwiftUI
import UIKit

/// UserDefaults-backed persistence for the user's "Keep Screen On"
/// choice (same struct-over-UserDefaults convention as `ThemeSettings` /
/// `TerminalToolbarSettings`). Default OFF — the screen sleeps normally
/// until the user opts in; an absent key or a foreign stored value also
/// reads as OFF, so a stale pref can never pin the idle timer disabled.
struct KeepAwakeSettings {
    private let defaults: UserDefaults
    private let key = "bicterm.terminal.keepScreenOn"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `true` only when the user explicitly enabled Keep Screen On.
    var keepScreenOn: Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    func setKeepScreenOn(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }

    /// Drops the stored choice; the next read returns the default (OFF).
    /// Used by UITEST setup so launch state is deterministic.
    func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// App-global keep-screen-on preference: the single write path behind the
/// Settings Terminal toggle. One instance lives on `SessionStore` so every
/// scene observes the same state. The model mirrors the preference onto
/// `UIApplication.shared.isIdleTimerDisabled` — at initialization (a
/// relaunch restores the persisted choice before the first frame) and on
/// every mutation, so turning it OFF always restores the idle timer.
///
/// `@MainActor` because `UIApplication` is main-actor-isolated (Swift 6
/// strict concurrency); the model is constructed on the main actor with
/// the rest of the `SessionStore` settings models.
@MainActor
@Observable
final class KeepAwakeModel {
    private let settings: KeepAwakeSettings

    /// Current preference. SwiftUI observes this; the Settings toggle
    /// binds to it.
    private(set) var keepScreenOn: Bool

    init(settings: KeepAwakeSettings = KeepAwakeSettings()) {
        self.settings = settings
        self.keepScreenOn = settings.keepScreenOn
        apply()
    }

    /// Persists and publishes a new choice, applying it to the idle
    /// timer immediately. No-op when unchanged.
    func setKeepScreenOn(_ enabled: Bool) {
        guard enabled != keepScreenOn else { return }
        keepScreenOn = enabled
        settings.setKeepScreenOn(enabled)
        apply()
    }

    /// Back to the default (OFF); restores the idle timer and clears the
    /// persisted choice.
    func reset() {
        setKeepScreenOn(false)
        settings.reset()
    }

    /// The single application point: the UIKit idle timer mirrors the
    /// preference exactly — ON disables it (the screen stays on), OFF
    /// always re-enables it.
    private func apply() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}
