import Foundation

struct SessionID: Codable, Hashable {
    let value: UUID

    init() {
        self.value = UUID()
    }

    init(value: UUID) {
        self.value = value
    }
}

/// Value keying the single Settings window. The WindowGroup is value-typed
/// so presenting the SAME value again brings the already-open Settings
/// window to the front instead of opening a duplicate (the documented
/// `openWindow(id:value:)` behavior for value-typed groups).
struct SettingsWindowValue: Codable, Hashable {
    static let main = SettingsWindowValue()
}
