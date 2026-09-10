import SwiftUI

/// Content of one Herdr workspace window: the session its window value
/// names. Restored windows whose session no longer exists return to the
/// connection list (never auto-dismissing the last visible scene).
@MainActor
struct HerdrWindowRoot: View {
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let center: HerdrWorkspaceCenter
    let windowSessionID: UUID?

    var body: some View {
        Group {
            if let windowSessionID,
               let entry = center.entry(id: windowSessionID) {
                HerdrWorkspaceView(
                    model: entry.model,
                    endpointLabel: entry.label,
                    onClose: {
                        Task {
                            await center.close(id: entry.id)
                        }
                    }
                )
                .id(entry.id)
            } else {
                ConnectionListContainer(store: store)
            }
        }
        .terminalStyle()
    }
}
