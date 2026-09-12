import SwiftUI

/// Applies the app-global appearance preference at a scene root: System
/// (nil) leaves the scene following the device; Dark/Light pin the window
/// and everything presented inside it. Reading the observable model in a
/// ViewModifier body keeps the override live — a Settings change re-renders
/// every scene with the new scheme, no relaunch needed.
private struct AppAppearanceModifier: ViewModifier {
    let theme: ThemeModel

    func body(content: Content) -> some View {
        content.preferredColorScheme(theme.colorSchemeOverride)
    }
}

private extension View {
    func appAppearance(_ theme: ThemeModel) -> some View {
        modifier(AppAppearanceModifier(theme: theme))
    }
}

/// Terminal window whose restored SessionID has no live scene yet. Asks
/// the store whether a termination snapshot exists for that window's
/// original session (state-restored windows keep their value across
/// launches): when it does, the window becomes a reconnect-required scene;
/// otherwise it returns to the connection list. Never auto-dismisses — closing
/// the app's last visible scene would background the whole app.
private struct RestoredTerminalWindowHost: View {
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let sessionID: SessionID
    @State private var resolutionFinished = false

    var body: some View {
        Group {
            if resolutionFinished {
                ConnectionListContainer(store: store)
            } else {
                ProgressView("Restoring session")
            }
        }
        .terminalStyle()
        .task(id: sessionID.value) {
            await store.resolveRestoredWindow(sessionID: sessionID.value)
            resolutionFinished = true
        }
    }
}

/// Content of one terminal window: the session its window value names,
/// OR any other live session the user picked from the switcher (in-window
/// switching — the picked session's cached surface moves into THIS window
/// and the previously shown one keeps running detached).
@MainActor
private struct TerminalWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

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
                fontModel: store.terminalFont,
                themeModel: store.theme,
                onConnectRequested: { connection in
                    listPresented = false
                    let descriptor = store.openSession(for: connection)
                    if supportsMultipleWindows {
                        openWindow(id: "terminal", value: SessionID(value: descriptor.id))
                    } else {
                        switchedSessionID = descriptor.id
                    }
                },
                onClose: { listPresented = false }
            )
            .terminalStyle()
        }
        .onAppear { registerHosting() }
        .onChange(of: switchedSessionID) { _, _ in registerHosting() }
        .onDisappear { deregisterHosting() }
    }

    /// The session this window currently shows (in-window switch wins over
    /// the window's creation value).
    private var shownSessionID: UUID? {
        switchedSessionID ?? windowSessionID
    }

    /// Keeps the store's window→session hosting map current so the session
    /// menu can FOCUS the window already hosting a picked session.
    private func registerHosting() {
        guard let windowSessionID, let shown = shownSessionID else { return }
        store.noteWindowHosting(windowValue: windowSessionID, shows: shown)
    }

    private func deregisterHosting() {
        guard let windowSessionID else { return }
        store.noteWindowClosed(windowValue: windowSessionID)
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
            Group {
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
            .appAppearance(sessionStore.theme)
        }

        WindowGroup("Terminal", id: "terminal", for: SessionID.self) { $sessionID in
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    TerminalWindowRoot(store: sessionStore, windowSessionID: sessionID?.value)
                }
                #else
                TerminalWindowRoot(store: sessionStore, windowSessionID: sessionID?.value)
                #endif
            }
            .appAppearance(sessionStore.theme)
        }

        WindowGroup("Herdr Workspace", id: "herdr", for: SessionID.self) { $sessionID in
            Group {
                #if DEBUG
                // iPadOS persists scene sessions across launches and hard
                // shutdowns: a stale herdr scene restored during a
                // `-uitest-terminal-preview` run would render the connection
                // list (HerdrWindowRoot's nil-state) and shadow the preview.
                // Every WindowGroup must mirror the test gate.
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    HerdrWindowRoot(
                        store: sessionStore,
                        center: HerdrWorkspaceCenter.shared,
                        windowSessionID: sessionID?.value
                    )
                }
                #else
                HerdrWindowRoot(
                    store: sessionStore,
                    center: HerdrWorkspaceCenter.shared,
                    windowSessionID: sessionID?.value
                )
                #endif
            }
            .appAppearance(sessionStore.theme)
        }

        WindowGroup("Settings", id: "settings", for: SettingsWindowValue.self) { _ in
            Group {
                #if DEBUG
                // Same restoration hazard as the herdr scene above: a stale
                // Settings window restored under `-uitest-terminal-preview`
                // would shadow the preview. Every WindowGroup must mirror
                // the test gate.
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    NavigationStack {
                        SettingsView(
                            fontModel: sessionStore.terminalFont,
                            themeModel: sessionStore.theme
                        )
                    }
                    .terminalStyle()
                }
                #else
                NavigationStack {
                    SettingsView(
                        fontModel: sessionStore.terminalFont,
                        themeModel: sessionStore.theme
                    )
                }
                .terminalStyle()
                #endif
            }
            .appAppearance(sessionStore.theme)
        }
    }
}
