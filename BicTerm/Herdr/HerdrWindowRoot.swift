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
                herdrWorkspace(for: entry)
                    .id(entry.id)
            } else {
                ConnectionListContainer(store: store)
            }
        }
        .terminalStyle()
    }

    @ViewBuilder
    private func herdrWorkspace(for entry: HerdrWorkspaceCenter.Entry) -> some View {
        if let herd = entry.herd {
            HerdWorkspaceChromeView(
                model: entry.model,
                herd: herd,
                onClose: {
                    Task {
                        await center.close(id: entry.id)
                    }
                },
                onSelectMachine: { machine in
                    herd.apply(machine, in: entry.model)
                }
            )
        } else {
            HerdrWorkspaceView(
                model: entry.model,
                endpointLabel: entry.label,
                onClose: {
                    Task {
                        await center.close(id: entry.id)
                    }
                }
            )
        }
    }
}
