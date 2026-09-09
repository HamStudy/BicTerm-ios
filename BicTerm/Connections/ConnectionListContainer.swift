import SwiftUI
import BicTermCore

struct ConnectionListContainer: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    let store: SessionStore

    @State private var reauthenticationTarget: CoderServerEditorTarget?
    @State private var coderTunnelAlertConnection: Connection?
    @State private var coderConnectTarget: Connection?
    @State private var coverDescriptor: SessionStore.SessionDescriptor?
    @State private var restorableSessions: [SessionStore.RestorableSession] = []
    @State private var switcherPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if !restorableSessions.isEmpty {
                RestorableSessionsSection(entries: restorableSessions) { entry in
                    reconnectRestorable(entry)
                }
            }

            ConnectionListView(
                onConnectRequested: handleConnect,
                onOpenSessions: { switcherPresented = true }
            )
                .sheet(item: $reauthenticationTarget) { target in
                    NavigationStack {
                        CoderReauthenticationView(serverID: target.serverID)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .coderReauthenticationRequested)) { notification in
                    if let serverID = notification.userInfo?["serverID"] as? UUID {
                        reauthenticationTarget = CoderServerEditorTarget(serverID: serverID)
                    }
                }
                .alert(
                    "Coder tunnel not yet available",
                    isPresented: Binding(
                        get: { coderTunnelAlertConnection != nil },
                        set: { if !$0 { coderTunnelAlertConnection = nil } }
                    ),
                    presenting: coderTunnelAlertConnection
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { _ in
                    Text("Connecting to a Coder workspace requires a tunnel, which is not implemented yet.")
                }
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
        #if CODER_TUNNEL
        .sheet(item: $coderConnectTarget) { connection in
            CoderStartFlowView(
                connection: connection,
                onComplete: {
                    coderConnectTarget = nil
                    // Let the flow sheet finish dismissing before presenting
                    // the terminal cover from the same presenter.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        present(store.openSession(for: connection))
                    }
                },
                onCancel: { coderConnectTarget = nil }
            )
            .presentationDetents([.medium, .large])
            .terminalStyle()
        }
        #endif
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
        .task {
            await reloadRestorableSessions()
            #if DEBUG
            await SessionUITestDriver.run(store: store, present: present)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reloadRestorableSessions() }
            }
        }
    }

    private func handleConnect(_ connection: Connection) {
        guard connection.type == .coder else {
            present(store.openSession(for: connection))
            return
        }
        #if CODER_TUNNEL
        coderConnectTarget = connection
        #else
        coderTunnelAlertConnection = connection
        #endif
    }

    private func reconnectRestorable(_ entry: SessionStore.RestorableSession) {
        restorableSessions.removeAll { $0.id == entry.id }
        present(store.openRestoredSession(
            snapshot: entry.snapshot,
            connection: entry.connection,
            initiatesReconnect: true
        ))
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

private struct CoderServerEditorTarget: Identifiable, Hashable {
    var id: UUID { serverID }
    let serverID: UUID
}

struct CoderReauthenticationView: View {
    let serverID: UUID

    var body: some View {
        CoderServersListView(
            model: CoderServersModel(
                store: AppServices.shared.coderServerStore,
                connectionStore: AppServices.shared.connectionStore,
                makeClient: AppServices.shared.coderClientFactory
            )
        )
        .onAppear {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .coderOpenServerEditor,
                    object: nil,
                    userInfo: ["serverID": serverID]
                )
            }
        }
    }
}
