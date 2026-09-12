import SwiftUI

/// Live-session state, not a connection preference: two sessions to the same
/// host must remain independent. Kept through detach/reattach, discarded on
/// close or process exit; restoring an SSH snapshot starts with global defaults.
struct SessionAppearanceOverrides: Equatable {
    var theme: AppearancePreference?
    var fontSize: Double?
    var margin: TerminalMargin?
}

enum TerminalMargin: Double, CaseIterable, Sendable {
    case none = 0
    case small = 5
    case medium = 10
    case large = 20

    var label: String {
        switch self {
        case .none: "None (0 pt)"
        case .small: "Small (5 pt)"
        case .medium: "Medium (10 pt)"
        case .large: "Large (20 pt)"
        }
    }
}

struct TerminalMarginSettings {
    private let defaults: UserDefaults
    static let key = "bicterm.terminal.contentMargin"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var margin: TerminalMargin {
        guard defaults.object(forKey: Self.key) != nil else { return .small }
        return TerminalMargin(rawValue: defaults.double(forKey: Self.key)) ?? .small
    }

    func setMargin(_ margin: TerminalMargin) {
        defaults.set(margin.rawValue, forKey: Self.key)
    }
}

@MainActor
@Observable
final class TerminalMarginModel {
    private let settings: TerminalMarginSettings
    private(set) var margin: TerminalMargin

    init(settings: TerminalMarginSettings = TerminalMarginSettings()) {
        self.settings = settings
        margin = settings.margin
    }

    func setMargin(_ value: TerminalMargin) {
        margin = value
        settings.setMargin(value)
    }
}

extension SessionStore {
    func effectiveTheme(_ sceneID: String) -> AppearancePreference {
        appearanceOverrides[sceneID]?.theme ?? theme.preference
    }

    func effectiveFontSize(_ sceneID: String) -> Double {
        appearanceOverrides[sceneID]?.fontSize ?? terminalFont.size
    }

    func effectiveMargin(_ sceneID: String) -> TerminalMargin {
        appearanceOverrides[sceneID]?.margin ?? terminalMargin.margin
    }

    func setTheme(_ value: AppearancePreference?, sceneID: String) {
        appearanceOverrides[sceneID, default: SessionAppearanceOverrides()].theme = value
    }

    func setFontSize(_ value: Double?, sceneID: String) {
        appearanceOverrides[sceneID, default: SessionAppearanceOverrides()].fontSize = value.map(TerminalFontSettings.normalize)
        refreshSceneFonts()
    }

    func setMargin(_ value: TerminalMargin?, sceneID: String) {
        appearanceOverrides[sceneID, default: SessionAppearanceOverrides()].margin = value
    }

    func refreshSceneFonts() {
        for descriptor in descriptors.values {
            viewCache.applyFontSize(effectiveFontSize(descriptor.registrySceneID), for: descriptor.id)
        }
    }
}
