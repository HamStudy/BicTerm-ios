import SwiftUI

/// Applies the app-global appearance preference at a scene root: System
/// (nil) leaves the scene following the device; Dark/Light pin the window
/// and everything presented inside it. Reading the observable model in a
/// ViewModifier body keeps the override live — a Settings change re-renders
/// every scene with the new scheme, no relaunch needed.
private struct AppAppearanceModifier: ViewModifier {
    let theme: ThemeModel

    func body(content: Content) -> some View {
        content.sceneAppearance(theme.preference)
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
/// otherwise it returns to the connection list. Never dismisses on its
/// own — and the session-close path (TerminalWindowRoot) dismisses its
/// window only when another visible scene remains, because closing the
/// app's LAST visible scene would background the whole app.
private struct RestoredTerminalWindowHost: View {
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    let herdConnect: HerdSessionCoordinator
    let sessionID: SessionID
    @State private var resolutionFinished = false

    var body: some View {
        Group {
            if resolutionFinished {
                ConnectionListContainer(store: store, herdConnect: herdConnect)
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
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    let store: SessionStore
    let herdConnect: HerdSessionCoordinator
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
                ConnectionListContainer(store: store, herdConnect: herdConnect)
            } else if let windowSessionID {
                RestoredTerminalWindowHost(
                    store: store,
                    herdConnect: herdConnect,
                    sessionID: SessionID(value: windowSessionID)
                )
            } else {
                TerminalPlaceholderView(connectionName: "Terminal Session")
            }
        }
        .terminalStyle()
        .sheet(isPresented: $listPresented) {
            ConnectionListView(
                fontModel: store.terminalFont,
                themeModel: store.theme,
                osc52Model: store.osc52Clipboard,
                onConnectRequested: { connection in
                    listPresented = false
                    let descriptor = store.openSession(for: connection)
                    if supportsMultipleWindows, !store.canReplaceSession(shownSessionID) {
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
        .onChange(of: windowSessionID.flatMap { store.pendingWindowAttachments[$0] }, initial: true) {
            guard let windowSessionID,
                  let attached = store.takeWindowAttachment(for: windowSessionID) else { return }
            // A retry may have made the old session live since it was selected.
            if store.canReplaceSession(shownSessionID) {
                switchedSessionID = attached
                registerHosting()
            } else {
                openWindow(id: "terminal", value: SessionID(value: attached))
            }
        }
        .onChange(of: switchedSessionID) { _, _ in registerHosting() }
        .onDisappear { deregisterHosting() }
        .sceneAppearance(effectiveTheme)
    }

    /// The session this window currently shows (in-window switch wins over
    /// the window's creation value).
    private var shownSessionID: UUID? {
        switchedSessionID ?? windowSessionID
    }

    private var effectiveTheme: AppearancePreference {
        guard let shownSessionID, let descriptor = store.descriptor(id: shownSessionID) else {
            return store.theme.preference
        }
        return store.effectiveTheme(descriptor.registrySceneID)
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
                    // Teardown already ran (closeNow → SessionStore.closeScene).
                    // The window now either dismisses — another visible scene
                    // remains, e.g. the connection-list window that opened
                    // this session — or falls through to the in-window
                    // connection list below: it is the app's last visible
                    // window, and dismissing it would background the app.
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
        // In-window switches must REBUILD the scene — see the matching
        // comment in ConnectionListContainer.
        .id(model.id)
    }
}

/// No scene content can observe a partially bootstrapped connection/key pool.
private struct ConnectionsBootstrapGate<Content: View>: View {
    let model: ConnectionsModel
    @ViewBuilder let content: () -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                content()
            } else {
                ProgressView("Loading connections")
            }
        }
        .environment(model)
        .task {
            await model.bootstrap()
            ready = true
        }
    }
}

@main
struct BicTermApp: App {
    @State private var connectionsModel = ConnectionsModel()
    @State private var sessionStore = SessionStore()
    // App-scoped so the herd workspace presentations (full-screen cover on
    // iPhone, herdr window on iPad) can surface this coordinator's TOFU
    // prompts above themselves (F3-B).
    @State private var herdConnect = HerdSessionCoordinator()

    init() {
        #if DEBUG
        UITestSupport.activate()
        #endif
    }

    var body: some Scene {
        WindowGroup("BicTerm") {
            ConnectionsBootstrapGate(model: connectionsModel) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    ConnectionListContainer(store: sessionStore, herdConnect: herdConnect)
                        .terminalStyle()
                        .modifier(UITestSettingsSceneOpener())
                }
                #else
                ConnectionListContainer(store: sessionStore, herdConnect: herdConnect)
                    .terminalStyle()
                #endif
            }
            .environment(sessionStore.terminalMargin)
            .environment(AppServices.shared.keyStore)
            .environment(AppServices.shared.keyAvailabilityPreferences)
        }

        WindowGroup("Terminal", id: "terminal", for: SessionID.self) { $sessionID in
            ConnectionsBootstrapGate(model: connectionsModel) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    TerminalWindowRoot(
                        store: sessionStore,
                        herdConnect: herdConnect,
                        windowSessionID: sessionID?.value
                    )
                }
                #else
                TerminalWindowRoot(
                    store: sessionStore,
                    herdConnect: herdConnect,
                    windowSessionID: sessionID?.value
                )
                #endif
            }
            .environment(sessionStore.terminalMargin)
            .environment(AppServices.shared.keyStore)
            .environment(AppServices.shared.keyAvailabilityPreferences)
        }

        WindowGroup("Herdr Workspace", id: "herdr", for: SessionID.self) { $sessionID in
            ConnectionsBootstrapGate(model: connectionsModel) {
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
                        herdConnect: herdConnect,
                        windowSessionID: sessionID?.value
                    )
                }
                #else
                HerdrWindowRoot(
                    store: sessionStore,
                    center: HerdrWorkspaceCenter.shared,
                    herdConnect: herdConnect,
                    windowSessionID: sessionID?.value
                )
                #endif
            }
            .appAppearance(sessionStore.theme)
            .environment(sessionStore.terminalMargin)
            .environment(AppServices.shared.keyStore)
            .environment(AppServices.shared.keyAvailabilityPreferences)
        }

        WindowGroup("Settings", id: "settings", for: SettingsWindowValue.self) { _ in
            ConnectionsBootstrapGate(model: connectionsModel) {
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
                            themeModel: sessionStore.theme,
                            osc52Model: sessionStore.osc52Clipboard
                        )
                    }
                    .terminalStyle()
                }
                #else
                NavigationStack {
                    SettingsView(
                        fontModel: sessionStore.terminalFont,
                        themeModel: sessionStore.theme,
                        osc52Model: sessionStore.osc52Clipboard
                    )
                }
                .terminalStyle()
                #endif
            }
            .appAppearance(sessionStore.theme)
            .environment(sessionStore.terminalMargin)
            .environment(AppServices.shared.keyStore)
            .environment(AppServices.shared.keyAvailabilityPreferences)
        }
    }
}
