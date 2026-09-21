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
                keepAwakeModel: store.keepAwake,
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
    let sessionStore: SessionStore
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
        #if DEBUG
        // Every scene's content flows through this gate, so the Settings
        // opener mounts in whichever scene iPadOS actually restores — a
        // full UI-suite run leaves the last-active archived scene as a
        // herdr/terminal window, and the main WindowGroup scene may never
        // be realized on launch (see UITestSettingsSceneOpener).
        .modifier(UITestSettingsSceneOpener())
        .modifier(UITestSessionDriverSeam(store: sessionStore))
        #endif
        .task {
            await model.bootstrap()
            ready = true
        }
    }
}

#if DEBUG
/// Runs the session-scene UI-test driver from whichever scene iPadOS
/// actually restores on launch. The driver's original mount —
/// `ConnectionListContainer`'s `.task` — only fires when a scene whose
/// content includes the connection list realizes (the main window, or a
/// restored terminal/herdr window's connection-list fallback). iPadOS
/// can instead restore the independent Settings window as the ONLY
/// realized scene — observed in a full iPad suite run right after a test
/// left the Settings window foreground: that launch showed SettingsView
/// alone, the driver never ran, no session opened, and every
/// session-scene wait in the next two tests timed out. Mounted on
/// `ConnectionsBootstrapGate` (every scene's content flows through it)
/// and firing from the first `.active` scene-phase transition — with the
/// `.task` replay for a cold launch that is already active when this
/// modifier subscribes, mirroring `UITestSettingsSceneOpener` — so
/// `openWindow` is never issued during scene startup (windows created
/// then never surface on iPad). The driver's own per-process latch makes
/// the multiple scene mounts and this seam racing the container's
/// `.task` mount harmless: exactly one `run` per launch.
///
/// iPad only (`supportsMultipleWindows`): on iPhone the single main
/// scene always realizes, and `ConnectionListContainer`'s cover-based
/// presentation path owns the driver.
private struct UITestSessionDriverSeam: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.scenePhase) private var scenePhase

    let store: SessionStore

    func body(content: Content) -> some View {
        content
            .task {
                if scenePhase == .active {
                    runDriverFromThisScene()
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    runDriverFromThisScene()
                }
            }
    }

    @MainActor
    private func runDriverFromThisScene() {
        guard supportsMultipleWindows else { return }
        Task { @MainActor in
            await SessionUITestDriver.run(store: store, present: present)
        }
    }

    /// Same window resolution as `ConnectionListContainer.present`'s
    /// iPad branch — the session lands in the same window either mount
    /// would have chosen.
    @MainActor
    private func present(_ descriptor: SessionStore.SessionDescriptor) {
        openWindow(
            id: "terminal",
            value: SessionID(value: store.presentationWindowValue(forSession: descriptor.id))
        )
    }
}
#endif

@main
struct BicTermApp: App {
    @State private var connectionsModel = ConnectionsModel()
    // Constructed in `init` (not as a default value): the DEBUG keep-awake
    // UI-test control below must run BEFORE SessionStore constructs
    // `KeepAwakeModel`, which applies the persisted pref to the UIKit
    // idle timer at init — a post-bootstrap reset would be too late.
    @State private var sessionStore: SessionStore
    // App-scoped so the herd workspace presentations (full-screen cover on
    // iPhone, herdr window on iPad) can surface this coordinator's TOFU
    // prompts above themselves (F3-B).
    @State private var herdConnect = HerdSessionCoordinator()

    init() {
        // A write to a socket whose peer died must surface as EPIPE, not
        // kill the process: the embedded herdr client (Rust staticlib —
        // its lang_start SIGPIPE-ignore never runs inside a host app)
        // writes to its Local-endpoint bridge socket after the relay
        // closes it on server death, and iOS leaves SIGPIPE at SIG_DFL.
        signal(SIGPIPE, SIG_IGN)
        // Opt this app out of the system press-and-hold accent palette so a
        // held key repeats instead (the same registration every terminal app
        // ships — Ghostty, VimR): iPadOS offers no user-facing setting for
        // it, and the palette is what swallows hardware key repeat.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        #if DEBUG
        UITestSupport.activate()
        // Keep-awake determinism: reset the persisted pref (unless this
        // launch deliberately preserves it) BEFORE the store below
        // constructs KeepAwakeModel — the model applies the pref to the
        // UIKit idle timer at init, so the driver's post-bootstrap reset
        // pattern (theme/font) cannot be used here.
        KeepAwakeUITestLaunchControl.apply()
        #endif
        sessionStore = SessionStore()
    }

    var body: some Scene {
        WindowGroup("BicTerm") {
            ConnectionsBootstrapGate(model: connectionsModel, sessionStore: sessionStore) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") {
                    TerminalPreviewScreen()
                        .terminalStyle()
                } else {
                    ConnectionListContainer(store: sessionStore, herdConnect: herdConnect)
                        .terminalStyle()
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
            ConnectionsBootstrapGate(model: connectionsModel, sessionStore: sessionStore) {
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
            ConnectionsBootstrapGate(model: connectionsModel, sessionStore: sessionStore) {
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
            ConnectionsBootstrapGate(model: connectionsModel, sessionStore: sessionStore) {
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
                            osc52Model: sessionStore.osc52Clipboard,
                            keepAwakeModel: sessionStore.keepAwake
                        )
                    }
                    .terminalStyle()
                }
                #else
                NavigationStack {
                    SettingsView(
                        fontModel: sessionStore.terminalFont,
                        themeModel: sessionStore.theme,
                        osc52Model: sessionStore.osc52Clipboard,
                        keepAwakeModel: sessionStore.keepAwake
                    )
                }
                .terminalStyle()
                #endif
            }
            .appAppearance(sessionStore.theme)
            #if DEBUG
            .modifier(UITestSettingsSceneDismisser())
            #endif
            .environment(sessionStore.terminalMargin)
            .environment(AppServices.shared.keyStore)
            .environment(AppServices.shared.keyAvailabilityPreferences)
        }
    }
}
