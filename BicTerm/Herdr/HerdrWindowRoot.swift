import SwiftUI

/// Content of one Herdr workspace window: the session its window value
/// names. Restored windows whose session no longer exists return to the
/// connection list (never auto-dismissing the last visible scene).
@MainActor
struct HerdrWindowRoot: View {
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let center: HerdrWorkspaceCenter
    let herdConnect: HerdSessionCoordinator
    let windowSessionID: UUID?

    var body: some View {
        Group {
            if let windowSessionID,
               let entry = center.entry(id: windowSessionID) {
                herdrWorkspace(for: entry)
                    .id(entry.id)
            } else {
                ConnectionListContainer(store: store, herdConnect: herdConnect)
            }
        }
        .terminalStyle()
    }

    @ViewBuilder
    private func herdrWorkspace(for entry: HerdrWorkspaceCenter.Entry) -> some View {
        // Embedded TUI (plan herdr-embed T4-T7): the real herdr client's
        // surface replaces the native workspace interior; herds seed the
        // client's machine catalog per open so its own sidebar owns
        // multi-machine selection/input/health; Mode-A entries carry the
        // connection the embed runtime bridges through.
        HerdrEmbedWorkspaceView(
            endpointLabel: entry.label,
            onClose: {
                Task {
                    await center.close(id: entry.id)
                }
            },
            fontModel: store.terminalFont,
            embedConnection: entry.embedConnection,
            embedHerd: entry.herd,
            ownerID: entry.id,
            hostKeyVerifier: store.hostKeyVerifier
        )
    }
}
