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

/// Content of one terminal window: the session its window value names,
/// OR any other live session the user picked from the switcher (in-window
/// switching — the picked session's cached surface moves into THIS window
/// and the previously shown one keeps running detached).
@MainActor
private struct TerminalWindowRoot: View {
    let store: SessionStore
    let windowSessionID: UUID?

    @State private var switchedSessionID: UUID?
    @State private var listPresented = false

    var body: some View {
        Group {
            if let shown = switchedSessionID ?? windowSessionID,
               let descriptor = store.descriptor(id: shown),
               let model = store.sceneModel(for: descriptor.id) {
                sceneView(model: model)
            } else if forcesConnectionListForUITests {
                ConnectionListContainer(store: store)
            } else if let windowSessionID {
                RestoredTerminalWindowHost(store: store, sessionID: SessionID(value: windowSessionID))
            } else {
                TerminalPlaceholderView(connectionName: "Terminal Session")
            }
        }
        .terminalStyle()
        .sheet(isPresented: $listPresented) {
            ConnectionListView(
                onConnectRequested: { connection in
                    listPresented = false
                    let descriptor = store.openSession(for: connection)
                    switchedSessionID = descriptor.id
                },
                onClose: { listPresented = false }
            )
            .terminalStyle()
        }
    }

    private var forcesConnectionListForUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitest-force-connection-list")
        #else
        false
        #endif
    }

    private func sceneView(model: SessionSceneModel) -> some View {
        SessionSceneView(
            model: model,
            store: store,
            actions: SessionSceneActions(
                onPickSession: { pickedID in
                    switchedSessionID = pickedID
                },
                onNewConnection: { listPresented = true },
                onSessionClosed: {
                    switchedSessionID = nil
                }
            )
        )
        // In-window switches must REBUILD the scene — see the matching
        // comment in ConnectionListContainer.
        .id(model.id)
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
            TerminalWindowRoot(store: sessionStore, windowSessionID: sessionID?.value)
        }
    }
}
