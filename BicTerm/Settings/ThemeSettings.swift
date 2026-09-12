import SwiftUI

/// The user's app appearance choice: follow the device (System, the
/// default) or pin every window dark/light. Persisted by
/// ``ThemeSettings``; applied at each scene root by `BicTermApp`.
enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case dark
    case light

    /// Settings row and picker label.
    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// The `.preferredColorScheme` override applied at each scene root;
    /// nil means no override — every scene follows the device appearance.
    var colorSchemeOverride: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// UserDefaults-backed persistence for the app appearance preference (same
/// struct-over-UserDefaults convention as `TerminalFontSettings` /
/// `TerminalToolbarSettings`). An absent key means System (no explicit
/// choice, follow the device); a foreign or unknown stored value also reads
/// as System, so a stale pref can never pin the app to an appearance the
/// user did not choose.
struct ThemeSettings {
    private let defaults: UserDefaults
    private let key = "bicterm.appearance.theme"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preference: AppearancePreference {
        guard let raw = defaults.string(forKey: key),
              let stored = AppearancePreference(rawValue: raw) else {
            return .system
        }
        return stored
    }

    /// Dark/Light persist an explicit choice; System REMOVES the key —
    /// absent means "no explicit choice, follow the device".
    func setPreference(_ preference: AppearancePreference) {
        switch preference {
        case .system:
            defaults.removeObject(forKey: key)
        case .dark, .light:
            defaults.set(preference.rawValue, forKey: key)
        }
    }

    /// Drops the stored choice; the next read returns `.system`.
    func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// App-global appearance preference: the single write path behind the
/// Settings theme picker. One instance shared by every scene, so a change
/// re-themes all windows at once — `BicTermApp` applies
/// ``colorSchemeOverride`` via `.preferredColorScheme` at each WindowGroup
/// root, and SwiftTerm surfaces follow through UIKit trait propagation
/// (`TerminalContainerView.applyNativeTerminalColors`). On iPad every
/// window shares this one pref, consistent with the terminal font size.
@MainActor
@Observable
final class ThemeModel {
    private var settings: ThemeSettings

    /// Current preference. SwiftUI observes this; a change re-renders the
    /// scene roots with the new override.
    private(set) var preference: AppearancePreference

    init(settings: ThemeSettings = ThemeSettings()) {
        self.settings = settings
        self.preference = settings.preference
    }

    /// The scene-level color-scheme override; nil under System.
    var colorSchemeOverride: ColorScheme? {
        preference.colorSchemeOverride
    }

    /// Persists and publishes a new preference. No-op when unchanged.
    func setPreference(_ newValue: AppearancePreference) {
        guard newValue != preference else { return }
        preference = newValue
        settings.setPreference(newValue)
    }

    /// Back to System; clears the persisted choice.
    func reset() {
        setPreference(.system)
    }
}
