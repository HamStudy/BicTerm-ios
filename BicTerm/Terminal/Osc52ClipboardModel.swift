import Foundation

/// @Observable wrapper around ``Osc52ClipboardSettings`` for the
/// Settings UI. SwiftUI reads `writesEnabled` to render the toggle and
/// calls `setWritesEnabled(_:)` on user interaction. One instance lives
/// on `SessionStore` so every scene observes the same toggle state.
@MainActor
@Observable
final class Osc52ClipboardModel {
    private let settings: Osc52ClipboardSettings

    init(settings: Osc52ClipboardSettings = Osc52ClipboardSettings()) {
        self.settings = settings
    }

    var writesEnabled: Bool {
        settings.writesEnabled
    }

    func setWritesEnabled(_ enabled: Bool) {
        settings.setWritesEnabled(enabled)
    }

    /// Drops the persisted choice so the next read returns the default
    /// (ON). UITEST-only.
    func reset() {
        settings.reset()
    }
}
