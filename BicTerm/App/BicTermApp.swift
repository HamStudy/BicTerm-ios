import SwiftUI

/// Terminal window whose restored SessionID has no live scene yet. Asks
/// the store whether a termination snapshot exists for that window's
/// original session (state-restored windows keep their value across
/// launches): when it does, the window becomes a reconnect-required scene;
/// otherwise it shows an inert placeholder. Never auto-dismisses — closing
/// the app's last visible scene would background the whole app.
private struct RestoredTerminalWindowHost: View {
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let sessionID: SessionID

    var body: some View {
        TerminalPlaceholderView(connectionName: "Terminal Session")
            .terminalStyle()
            .task(id: sessionID.value) {
                await store.resolveRestoredWindow(sessionID: sessionID.value)
            }
    }
}

@main
struct BicTermApp: App {
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup("BicTerm") {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                TerminalPreviewScreen()
                    .terminalStyle()
            } else {
                ConnectionListContainer(store: sessionStore)
                    .terminalStyle()
            }
            #else
            ConnectionListContainer(store: sessionStore)
                .terminalStyle()
            #endif
        }

        WindowGroup("Terminal", id: "terminal", for: SessionID.self) { $sessionID in
            if let sessionID,
               let descriptor = sessionStore.descriptor(id: sessionID.value),
               let model = sessionStore.sceneModel(for: descriptor.id) {
                SessionSceneView(
                    model: model,
                    agentPresenter: sessionStore.agentPresenter
                )
                .terminalStyle()
            } else if let sessionID {
                RestoredTerminalWindowHost(store: sessionStore, sessionID: sessionID)
            } else {
                TerminalPlaceholderView(connectionName: "Terminal Session")
                    .terminalStyle()
            }
        }
    }
}
