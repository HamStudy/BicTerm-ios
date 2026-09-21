import BicTermCore
import SwiftUI

/// Content of one Herdr workspace window: the session its window value
/// names. Restored windows whose session no longer exists return to the
/// connection list (never auto-dismissing the last visible scene).
@MainActor
struct HerdrWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let center: HerdrWorkspaceCenter
    let herdConnect: HerdSessionCoordinator
    let windowSessionID: UUID?

    /// Compact-split fallback (supportsMultipleWindows == false): the chrome
    /// menu's session jump, or a connect from the list sheet, attaches the
    /// terminal session IN this window — TerminalWindowRoot's in-window
    /// switch, mirrored for the herdr window.
    @State private var switchedSessionID: UUID?
    @State private var listPresented = false

    var body: some View {
        Group {
            if let switched = switchedSessionID,
               let descriptor = store.descriptor(id: switched),
               let model = store.sceneModel(for: descriptor.id) {
                SessionSceneView(
                    model: model,
                    store: store,
                    actions: SessionSceneActions(
                        onPickSession: { pickedID in
                            switchedSessionID = pickedID
                        },
                        onNewConnection: { listPresented = true },
                        onSessionClosed: {
                            // Teardown already ran (SessionSceneView's
                            // close path). The window now either dismisses
                            // — another visible scene remains — or falls
                            // through to the workspace / connection list
                            // below: it is the app's last visible window,
                            // and dismissing it would background the app.
                            switchedSessionID = nil
                            if AppSceneCounter.shouldDismissWindow(
                                supportsMultipleWindows: supportsMultipleWindows,
                                visibleWindowSceneCount: AppSceneCounter.visibleWindowSceneCount()
                            ) {
                                dismissWindow()
                            }
                        }
                    )
                )
                // In-window switches must REBUILD the scene — see the
                // matching comment in ConnectionListContainer.
                .id(model.id)
            } else if let windowSessionID,
                      let entry = center.entry(id: windowSessionID) {
                herdrWorkspace(for: entry)
                    .id(entry.id)
            } else {
                ConnectionListContainer(store: store, herdConnect: herdConnect)
            }
        }
        .terminalStyle()
        .sheet(isPresented: $listPresented) {
            ConnectionListView(
                fontModel: store.terminalFont,
                themeModel: store.theme,
                osc52Model: store.osc52Clipboard,
                keepAwakeModel: store.keepAwake,
                onConnectRequested: { connection in
                    listPresented = false
                    connectFromListSheet(connection)
                },
                onClose: { listPresented = false }
            )
            .terminalStyle()
        }
        .sceneAppearance(effectiveTheme)
    }

    /// The switched session's per-window override wins; the workspace itself
    /// follows the global theme (it has no per-session override — it is not
    /// a SessionStore session).
    private var effectiveTheme: AppearancePreference {
        guard let switchedSessionID,
              let descriptor = store.descriptor(id: switchedSessionID) else {
            return store.theme.preference
        }
        return store.effectiveTheme(descriptor.registrySceneID)
    }

    /// The list sheet's connect: herdr connections open their own workspace
    /// window; terminal connections mirror TerminalWindowRoot — a new window
    /// unless this one shows a replaceable (dead) switched session or the
    /// window is too compact for multi-window.
    private func connectFromListSheet(_ connection: Connection) {
        if connection.herdrEnabled {
            openWindow(id: "herdr", value: SessionID(value: center.openEmbed(connection: connection)))
            return
        }
        let descriptor = store.openSession(for: connection)
        let canSwapInWindow = switchedSessionID.map { store.canReplaceSession($0) } ?? false
        if supportsMultipleWindows, !canSwapInWindow {
            openWindow(id: "terminal", value: SessionID(value: descriptor.id))
        } else {
            switchedSessionID = descriptor.id
        }
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
                    // Close teardown completed first; the window now either
                    // dismisses — another visible scene remains — or falls
                    // through to the connection list: it is the app's last
                    // visible window, and dismissing it would background
                    // the app.
                    if AppSceneCounter.shouldDismissWindow(
                        supportsMultipleWindows: supportsMultipleWindows,
                        visibleWindowSceneCount: AppSceneCounter.visibleWindowSceneCount()
                    ) {
                        dismissWindow()
                    }
                }
            },
            store: store,
            onPickSession: { pickedID in
                // Reached only when this window can't open windows (compact
                // split): switch in-window, mirroring TerminalWindowRoot.
                switchedSessionID = pickedID
            },
            onNewConnection: { listPresented = true },
            fontModel: store.terminalFont,
            embedConnection: entry.embedConnection,
            embedHerd: entry.herd,
            ownerID: entry.id,
            hostKeyVerifier: store.hostKeyVerifier,
            osc52Settings: Osc52ClipboardSettings()
        )
    }
}
