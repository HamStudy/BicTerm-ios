import SwiftUI
import BicTermCore

struct ConnectionListContainer: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    let store: SessionStore

    @State private var reauthenticationTarget: CoderServerEditorTarget?
    @State private var coderTunnelAlertConnection: Connection?
    @State private var coverDescriptor: SessionStore.SessionDescriptor?
    @State private var restorableSessions: [SessionStore.RestorableSession] = []

    var body: some View {
        VStack(spacing: 0) {
            if !restorableSessions.isEmpty {
                RestorableSessionsSection(entries: restorableSessions) { entry in
                    reconnectRestorable(entry)
                }
            }

            ConnectionListView(onConnectRequested: handleConnect)
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
                        agentPresenter: store.agentPresenter,
                        onSessionClosed: { coverDescriptor = nil }
                    )
                } else {
                    TerminalPlaceholderView(connectionName: descriptor.connection.name)
                }
            }
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
        coderTunnelAlertConnection = connection
    }

    private func reconnectRestorable(_ entry: SessionStore.RestorableSession) {
        restorableSessions.removeAll { $0.id == entry.id }
        present(store.openRestoredSession(
            snapshot: entry.snapshot,
            connection: entry.connection,
            initiatesReconnect: true
        ))
    }

    /// iPad (regular width): every session opens as its own window. iPhone
    /// (compact): the terminal presents as a full-screen cover over the
    /// connection list.
    private func present(_ descriptor: SessionStore.SessionDescriptor) {
        if sizeClass == .regular {
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
