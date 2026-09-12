import SwiftUI
import BicTermCore

struct ConnectionListContainer: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    let store: SessionStore

    @State private var coverDescriptor: SessionStore.SessionDescriptor?
    @State private var herdrCoverSession: HerdrCoverSession?
    @State private var restorableSessions: [SessionStore.RestorableSession] = []
    @State private var switcherPresented = false

    private struct HerdrCoverSession: Identifiable {
        let id: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            if !restorableSessions.isEmpty {
                RestorableSessionsSection(entries: restorableSessions) { entry in
                    reconnectRestorable(entry)
                }
            }

            ConnectionListView(
                fontModel: store.terminalFont,
                themeModel: store.theme,
                onConnectRequested: handleConnect,
                onOpenSessions: { switcherPresented = true },
                onForgetHost: { connection in
                    Task { await forgetHostData(connection) }
                }
            )
        }
        .fullScreenCover(item: $coverDescriptor) { descriptor in
            Group {
                if let model = store.sceneModel(for: descriptor.id) {
                    SessionSceneView(
                        model: model,
                        store: store,
                        actions: SessionSceneActions(
                            onPickSession: { pickedID in
                                if let picked = store.descriptor(id: pickedID) {
                                    coverDescriptor = picked
                                }
                            },
                            onNewConnection: { coverDescriptor = nil },
                            onSessionClosed: {
                                if coverDescriptor?.id == descriptor.id {
                                    coverDescriptor = nil
                                }
                            }
                        )
                    )
                    // Session switches must REBUILD the scene (fresh
                    // representable identity) — otherwise SwiftUI updates
                    // the old placement in place and the terminal surface
                    // never swaps to the newly attached session.
                    .id(model.id)
                } else {
                    TerminalPlaceholderView(connectionName: descriptor.connection.name)
                }
            }
            .terminalStyle()
        }
        .sheet(isPresented: $switcherPresented) {
            SessionSwitcherView(
                store: store,
                currentSessionID: coverDescriptor?.id,
                onPick: { pickedID in
                    switcherPresented = false
                    if let picked = store.descriptor(id: pickedID) {
                        present(picked)
                    }
                },
                onNewConnection: { switcherPresented = false }
            )
            .terminalStyle()
        }
        .sheet(isPresented: mainWindowAgentSheetBinding) {
            if let request = store.agentPresenter.pendingRequest {
                AgentApprovalSheetView(
                    request: request,
                    sessionDisplayName: store.agentPresenter.routing?.sessionDisplayName ?? "Session",
                    onDecision: { store.agentPresenter.resolve($0) }
                )
            }
        }
        .fullScreenCover(item: $herdrCoverSession) { cover in
            if let entry = HerdrWorkspaceCenter.shared.entry(id: cover.id) {
                HerdrWorkspaceView(
                    model: entry.model,
                    endpointLabel: entry.label,
                    onClose: {
                        Task {
                            await HerdrWorkspaceCenter.shared.close(id: entry.id)
                        }
                        herdrCoverSession = nil
                    }
                )
                .id(entry.id)
                .terminalStyle()
            }
        }
        .task {
            await reloadRestorableSessions()
            #if DEBUG
            await SessionUITestDriver.run(store: store, present: present)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reloadRestorableSessions() }
                #if DEBUG
                openHerdrFixtureReplayOnce()
                #endif
            }
        }
    }

    private func handleConnect(_ connection: Connection) {
        present(store.openSession(for: connection))
    }

    /// Herdr sessions present through the same path as SSH sessions: their
    /// own window on iPad (T12 user directive), a full-screen cover on
    /// iPhone. T16's entry replays committed fixture frames; T19's endpoint
    /// profiles open real SSH-backed sessions through this same presenter.
    private func presentHerdr(sessionID: UUID) {
        if supportsMultipleWindows {
            openWindow(id: "herdr", value: SessionID(value: sessionID))
        } else {
            herdrCoverSession = HerdrCoverSession(id: sessionID)
        }
    }

    #if DEBUG
    @MainActor private static var didOpenHerdrReplay = false

    /// openWindow during scene STARTUP creates windows that never surface
    /// (observed on iPad); the replay bootstrap therefore runs once, from
    /// the first .active scene-phase transition.
    private func openHerdrFixtureReplayOnce() {
        guard HerdrWorkspaceUITest.isEnabled, !Self.didOpenHerdrReplay else { return }
        Self.didOpenHerdrReplay = true
        let id = HerdrWorkspaceCenter.shared.open { model in
            HerdrWorkspaceUITest.connectReplay(model: model)
        }
        presentHerdr(sessionID: id)
    }
    #endif

    private func reconnectRestorable(_ entry: SessionStore.RestorableSession) {
        restorableSessions.removeAll { $0.id == entry.id }
        present(store.openRestoredSession(
            snapshot: entry.snapshot,
            connection: entry.connection,
            initiatesReconnect: true
        ))
    }

    /// Per-host forget (T20): clears trust, stored passwords, restorable
    /// sessions, and herdr settings for one host through the same stores
    /// this container reads; the connection entry itself is kept.
    private func forgetHostData(_ connection: Connection) async {
        let service = HerdrHostForgetService(
            dependencies: .live(sessionStore: store)
        )
        _ = await service.forget(connection: connection)
        await reloadRestorableSessions()
    }

    /// On iPad every new session opens its own window, including narrow
    /// multitasking layouts. On iPhone the terminal uses a cover over the
    /// connection list.
    private func present(_ descriptor: SessionStore.SessionDescriptor) {
        if supportsMultipleWindows {
            openWindow(id: "terminal", value: SessionID(value: descriptor.id))
        } else {
            coverDescriptor = descriptor
        }
    }

    private func reloadRestorableSessions() async {
        restorableSessions = await store.loadRestorableSessions()
    }

    /// Fallback presentation surface for agent prompts whose originating
    /// scene no longer exists.
    private var mainWindowAgentSheetBinding: Binding<Bool> {
        Binding(
            get: { store.agentPresenter.routing?.target == .mainWindow },
            set: { presented in
                if !presented { store.agentPresenter.denyPendingIfMainWindow() }
            }
        )
    }
}
