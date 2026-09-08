import BicTermCore
import Foundation
import Observation

/// View-model state owned by ``ConnectionEditorView`` for live selection of a
/// configured Coder server and one of its workspaces.
///
/// The model does not cache workspace lists indefinitely. On every appearance
/// it revalidates: it renders the previous value immediately (stale), then loads
/// fresh data (revalidate), and reconciles the current selection. If the
/// selected workspace disappears or is no longer running, the selection is
/// cleared.
@MainActor
@Observable
final class CoderWorkspaceConnectionModel {
    enum LoadingState: Equatable {
        case idle
        case loading
        case staleRevalidating(workspaces: [CoderWorkspace])
        case loaded(workspaces: [CoderWorkspace])
        case empty
        case unauthorized(server: CoderServer)
        case unreachable(server: CoderServer)
        case serverError(server: CoderServer, statusCode: Int)
        case networkError(server: CoderServer)
    }

    private let coderServerStore: any CoderServerStoreProtocol
    private let coderTokenStore: any CoderTokenStoring
    private let clientFactory: CoderClientFactory

    private(set) var servers: [CoderServer] = []
    private(set) var selectedServerID: UUID?
    private(set) var selectedWorkspaceID: UUID?
    private(set) var selectedAgentID: UUID?
    private(set) var loadingState: LoadingState = .idle
    private var selectedWorkspaceSnapshot: CoderWorkspace?
    private var displayedWorkspaceSnapshot: CoderWorkspace?
    private var lastLoadedWorkspaces: [CoderWorkspace]?

    init(
        coderServerStore: any CoderServerStoreProtocol,
        coderTokenStore: any CoderTokenStoring,
        clientFactory: @escaping CoderClientFactory
    ) {
        self.coderServerStore = coderServerStore
        self.coderTokenStore = coderTokenStore
        self.clientFactory = clientFactory
    }

    var selectedServer: CoderServer? {
        guard let selectedServerID else { return nil }
        return servers.first { $0.id == selectedServerID }
    }

    var selectedWorkspace: CoderWorkspace? {
        selectedWorkspaceSnapshot ?? currentWorkspace(for: selectedWorkspaceID)
    }

    var selectedServerName: String {
        selectedServer?.name ?? ""
    }

    var selectedWorkspaceName: String {
        selectedWorkspace?.name ?? ""
    }

    var hasServers: Bool {
        !servers.isEmpty
    }

    /// Connected agents of the latest build of the selected workspace
    /// (spec §5.1 — agent identities come from build resources).
    var selectedWorkspaceConnectedAgents: [CoderWorkspaceAgent] {
        guard let selectedWorkspace else { return [] }
        return selectedWorkspace.agents.filter(\.isConnected)
    }

    /// Spec §5.2: ambiguity is never auto-picked — with more than one
    /// eligible agent the user must choose explicitly before saving.
    var requiresExplicitAgent: Bool {
        selectedWorkspaceConnectedAgents.count > 1
    }

    var selectedAgent: CoderWorkspaceAgent? {
        guard let selectedAgentID else { return nil }
        return selectedWorkspaceConnectedAgents.first { $0.id == selectedAgentID }
    }

    var canSave: Bool {
        selectedServer != nil
            && selectedWorkspace?.isConnectable == true
            && (!requiresExplicitAgent || selectedAgent != nil)
    }

    var noServersMessage: String {
        "Add a Coder server in Settings to choose a workspace."
    }

    func prepareForInitialValues(
        serverID: UUID?,
        workspaceID: UUID?,
        agentID: UUID? = nil
    ) {
        self.selectedServerID = serverID
        self.selectedWorkspaceID = workspaceID
        if selectedWorkspaceSnapshot == nil, let workspaceID {
            selectedWorkspaceSnapshot = selectedWorkspaceSnapshotBackfill(id: workspaceID)
        }
        if let agentID, selectedWorkspaceConnectedAgents.contains(where: { $0.id == agentID }) {
            selectedAgentID = agentID
        } else {
            selectedAgentID = nil
        }
    }

    func reloadServers() async {
        do {
            servers = try await coderServerStore.loadCoderServers()
            if let selectedServerID, servers.first(where: { $0.id == selectedServerID }) == nil {
                clearSelection(reason: .serverRemoved)
                loadingState = .idle
            }
        } catch {
            servers = []
            loadingState = .idle
        }
    }

    func selectServer(_ server: CoderServer?) {
        guard let server else {
            clearSelection(reason: .manual)
            loadingState = .idle
            return
        }
        if selectedServerID != server.id {
            selectedServerID = server.id
            selectedWorkspaceID = nil
            selectedWorkspaceSnapshot = nil
            lastLoadedWorkspaces = nil
            loadingState = .idle
        }
    }

    func selectWorkspace(_ workspace: CoderWorkspace?) {
        selectedAgentID = nil
        guard let workspace else {
            selectedWorkspaceID = nil
            selectedWorkspaceSnapshot = nil
            return
        }
        selectedWorkspaceID = workspace.id
        selectedWorkspaceSnapshot = workspace
    }

    func selectAgent(_ agent: CoderWorkspaceAgent?) {
        selectedAgentID = agent?.id
    }

    /// Stale-build reconciliation for an explicitly picked agent: returns
    /// false when the fresh build no longer contains the pick, clearing it
    /// so the editor must ask again (spec §5.2 — never silently re-pick).
    func reconcileAgentSelection(id: UUID?) -> Bool {
        guard let id else { return true }
        if selectedWorkspaceConnectedAgents.contains(where: { $0.id == id }) {
            selectedAgentID = id
            return true
        }
        selectedAgentID = nil
        return false
    }

    func loadWorkspaces() async {
        guard let server = selectedServer else {
            loadingState = .idle
            return
        }

        let previousWorkspaces: [CoderWorkspace]?
        switch loadingState {
        case .loaded(let workspaces), .staleRevalidating(let workspaces):
            previousWorkspaces = workspaces
        default:
            previousWorkspaces = lastLoadedWorkspaces
        }

        if let previousWorkspaces {
            loadingState = .staleRevalidating(workspaces: previousWorkspaces)
        } else {
            loadingState = .loading
        }

        let client = clientFactory(coderTokenStore)
        do {
            let workspaces = try await client.workspaces(for: server)
            lastLoadedWorkspaces = workspaces
            reconcileSelection(against: workspaces)
            loadingState = workspaces.isEmpty ? .empty : .loaded(workspaces: workspaces)
        } catch let error as CoderClientError {
            switch error {
            case .unauthorized, .tokenStorageFailure:
                loadingState = .unauthorized(server: server)
                clearSelection(reason: .unauthorized)
            case .tlsFailure, .networkFailure:
                loadingState = .unreachable(server: server)
            case .serverError(let statusCode):
                loadingState = .serverError(server: server, statusCode: statusCode)
            default:
                loadingState = .networkError(server: server)
            }
        } catch {
            loadingState = .networkError(server: server)
        }
    }

    func coderReference() -> CoderReference? {
        guard let selectedServer,
              let selectedWorkspace,
              selectedWorkspace.isConnectable
        else { return nil }
        return CoderReference(serverID: selectedServer.id, workspaceID: selectedWorkspace.id)
    }

    func workspaceStatus() -> WorkspaceStatus? {
        let workspace = displayedWorkspaceSnapshot ?? selectedWorkspace
        guard let workspace else { return nil }
        if workspace.state == .running { return nil }
        return WorkspaceStatus(state: workspace.state, connectable: false)
    }

    private enum ClearReason {
        case manual
        case serverRemoved
        case unauthorized
        case stateChanged
        case missing
    }

    private func clearSelection(reason: ClearReason) {
        selectedWorkspaceID = nil
        selectedWorkspaceSnapshot = nil
        displayedWorkspaceSnapshot = nil
        lastLoadedWorkspaces = nil
        selectedAgentID = nil
        if reason == .serverRemoved || reason == .manual {
            selectedServerID = nil
        }
    }

    private func currentWorkspace(for workspaceID: UUID?) -> CoderWorkspace? {
        guard let workspaceID,
              let loaded = lastLoadedWorkspaces ?? loadedWorkspacesFromState()
        else { return nil }
        return loaded.first { $0.id == workspaceID }
    }

    private func loadedWorkspacesFromState() -> [CoderWorkspace]? {
        switch loadingState {
        case .loaded(let workspaces), .staleRevalidating(let workspaces):
            return workspaces
        default:
            return nil
        }
    }

    private func selectedWorkspaceSnapshotBackfill(id: UUID) -> CoderWorkspace? {
        guard let loaded = lastLoadedWorkspaces ?? loadedWorkspacesFromState()
        else { return nil }
        let workspace = loaded.first { $0.id == id }
        if let workspace, workspace.isConnectable {
            selectedWorkspaceID = workspace.id
            return workspace
        }
        return nil
    }

    private func reconcileSelection(against workspaces: [CoderWorkspace]) {
        if let currentID = selectedWorkspaceID,
           let found = workspaces.first(where: { $0.id == currentID }) {
            if found.isConnectable {
                selectedWorkspaceID = found.id
                selectedWorkspaceSnapshot = found
                displayedWorkspaceSnapshot = nil
            } else {
                selectedWorkspaceID = nil
                selectedWorkspaceSnapshot = nil
                displayedWorkspaceSnapshot = CoderWorkspace(
                    stateOnly: found.id,
                    name: found.name,
                    ownerName: found.ownerName,
                    state: found.state
                )
            }
        } else {
            selectedWorkspaceSnapshot = nil
            selectedWorkspaceID = nil
            displayedWorkspaceSnapshot = nil
        }
    }
}

extension CoderWorkspaceConnectionModel {
    public struct WorkspaceStatus: Equatable {
        public let state: CoderWorkspaceState
        public let connectable: Bool

        public init(state: CoderWorkspaceState, connectable: Bool) {
            self.state = state
            self.connectable = connectable
        }
    }
}



