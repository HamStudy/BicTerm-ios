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
        #if HERDR_EMBED
        // Embedded TUI (plan herdr-embed T4): the real herdr client's own
        // surface replaces the native workspace interior for both single
        // endpoints and herds (its machine sidebar owns multi-machine until
        // T6 seeds the catalog). Header composition is preserved by the
        // embed chrome; the native path survives below until T7 sign-off.
        HerdrEmbedWorkspaceView(
            endpointLabel: entry.label,
            onClose: {
                Task {
                    await center.close(id: entry.id)
                }
            },
            fontModel: store.terminalFont
        )
        #else
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
                },
                fontModel: store.terminalFont
            )
            // Herd machines connect only after this window is up; their
            // TOFU challenges must present above it (F3-B).
            .modifier(HerdTrustPromptPresenter(herdConnect: herdConnect))
        } else {
            HerdrWorkspaceView(
                model: entry.model,
                endpointLabel: entry.label,
                onClose: {
                    Task {
                        await center.close(id: entry.id)
                    }
                },
                fontModel: store.terminalFont
            )
        }
        #endif
    }
}
