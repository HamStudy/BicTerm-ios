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
