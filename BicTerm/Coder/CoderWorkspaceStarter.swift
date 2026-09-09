import BicTermCore
import Foundation
import Observation

/// App-side workspace view used by start-policy decisions: carries the
/// dormancy marker and build transition the list model does not decode.
struct CoderWorkspaceDetail: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let ownerName: String
    let dormantAt: String?
    let latestBuild: LatestBuild

    struct LatestBuild: Decodable, Equatable, Sendable {
        let status: String
        let transition: String
        let agents: [CoderWorkspaceAgent]
        let agentLifecycles: [UUID: String]
    }

    var isRunning: Bool {
        latestBuild.status == "running"
    }

    var isDormant: Bool {
        guard let dormantAt else { return false }
        return !dormantAt.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerName = "owner_name"
        case dormantAt = "dormant_at"
        case latestBuild = "latest_build"
    }

    private struct RawBuild: Decodable {
        let status: String?
        let transition: String?
        let resources: [Resource]?
    }

    private struct Resource: Decodable {
        let agents: [CoderWorkspaceAgent]?
        let lifecycleAgents: [LifecycleAgent]?

        private enum CodingKeys: String, CodingKey {
            case agents
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agents = try container.decodeIfPresent([CoderWorkspaceAgent].self, forKey: .agents)
            lifecycleAgents = try container.decodeIfPresent([LifecycleAgent].self, forKey: .agents)
        }
    }

    private struct LifecycleAgent: Decodable {
        let id: UUID
        let lifecycleState: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case lifecycleState = "lifecycle_state"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        dormantAt = try container.decodeIfPresent(String.self, forKey: .dormantAt)
        let raw = try container.decodeIfPresent(RawBuild.self, forKey: .latestBuild)
        let resources = raw?.resources ?? []
        latestBuild = LatestBuild(
            status: raw?.status ?? "",
            transition: raw?.transition ?? "",
            agents: resources.flatMap { $0.agents ?? [] },
            agentLifecycles: Dictionary(
                uniqueKeysWithValues: resources
                    .flatMap { $0.lifecycleAgents ?? [] }
                    .compactMap { agent in
                        agent.lifecycleState.map { (agent.id, $0) }
                    }
            )
        )
    }
}

enum CoderStartFailure: Error, Equatable {
    case unauthorized
    case serverUnreachable
    case workspaceMissing
    case workspaceDormant
    case startRejected(statusCode: Int)
    case parameterMismatch
    case buildFailed(status: String)
    case agentStartupFailed(state: String)
    case agentSelectionRequired
    case startAmbiguous
    case deadlineExceeded

    var title: String {
        switch self {
        case .unauthorized: "Authentication required"
        case .serverUnreachable: "Coder server unreachable"
        case .workspaceMissing: "Workspace not found"
        case .workspaceDormant: "Workspace is dormant"
        case .startRejected: "Start request rejected"
        case .parameterMismatch: "Startup parameters required"
        case .buildFailed: "Workspace build failed"
        case .agentStartupFailed: "Agent startup failed"
        case .agentSelectionRequired: "Agent selection required"
        case .startAmbiguous: "Start result is unknown"
        case .deadlineExceeded: "Startup timed out"
        }
    }

    var message: String {
        switch self {
        case .unauthorized:
            "The Coder session token was rejected. Reauthenticate the server and try again."
        case .serverUnreachable:
            "The Coder server could not be reached. Check the network and try again."
        case .workspaceMissing:
            "This workspace no longer exists on the server. Edit or delete the connection."
        case .workspaceDormant:
            "Reactivate this workspace in the Coder dashboard, then connect again. BicTerm did not send a start request."
        case .startRejected(let statusCode):
            "The server rejected the start request (HTTP \(statusCode)). No build was created."
        case .parameterMismatch:
            "The template requires parameter answers before this workspace can start. BicTerm never answers parameters for you — update the workspace in Coder, then retry."
        case .buildFailed(let status):
            "The workspace build ended in “\(status)”. Review the build logs in Coder before retrying."
        case .agentStartupFailed(let state):
            "The selected agent ended startup in “\(state)”. Review the activity below, then retry explicitly."
        case .agentSelectionRequired:
            "The latest build does not expose one unambiguous agent. Open the connection editor and choose an agent."
        case .startAmbiguous:
            "The start request may have reached the server, but no start build appeared after re-fetching. Check Coder before retrying to avoid a duplicate build."
        case .deadlineExceeded:
            "The workspace did not become ready within 10 minutes. The start request was accepted — check its state in Coder before retrying to avoid a duplicate build."
        }
    }
}

/// Spec §6.1/§6.2 start lifecycle for the explicit start-stopped policy:
/// one start POST (`reason: ssh_connection`), network-ambiguity resolution
/// that re-fetches the build before ever retrying the POST, and a bounded
/// (10 minute) follow of build → agent-connection readiness with a layered
/// phase display. Never supplies template parameters or lifecycle answers.
@MainActor
@Observable
final class CoderWorkspaceStarter {
    enum Phase: Equatable {
        case idle
        case checkingParameters
        case starting
        case waitingForBuild(String)
        case waitingForAgent(String)
        case ready
        case failed(CoderStartFailure)
    }

    static let startupDeadline: TimeInterval = 600
    private static let pollInterval: UInt64 = 2_000_000_000

    private let loader: any CoderRequestLoading

    private(set) var phase: Phase = .idle
    private(set) var logTrail: [String] = []
    private var startPosts = 0

    init(loader: (any CoderRequestLoading)? = nil) {
        self.loader = loader ?? AppServices.shared.coderRequestLoader
    }

    var startPostCount: Int {
        startPosts
    }

    func reset() {
        phase = .idle
        logTrail = []
        startPosts = 0
    }

    // MARK: - Reads

    func fetchServerVersion(server: CoderServer) async -> String? {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("api/v2/buildinfo"))
        request.httpMethod = "GET"
        let response: CoderHTTPResponse
        do {
            response = try await loader.load(request)
        } catch {
            return nil
        }
        guard response.statusCode == 200 else { return nil }
        struct BuildInfo: Decodable {
            let version: String?
        }
        return (try? JSONDecoder().decode(BuildInfo.self, from: response.body))?.version
    }

    func fetchWorkspace(
        server: CoderServer,
        token: String,
        workspaceID: UUID
    ) async throws(CoderStartFailure) -> CoderWorkspaceDetail {
        var request = URLRequest(
            url: server.baseURL.appendingPathComponent("api/v2/workspaces/\(workspaceID.uuidString.lowercased())")
        )
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        let response = try await perform(request)
        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(CoderWorkspaceDetail.self, from: response.body)
            } catch {
                throw .serverUnreachable
            }
        case 401, 403:
            throw .unauthorized
        case 404:
            throw .workspaceMissing
        default:
            throw .serverUnreachable
        }
    }

    // MARK: - Start (spec §6.1)

    /// Runs the full explicit start: autostart parameter gate, single POST,
    /// ambiguity-safe retry, and the bounded readiness follow. Returns nil
    /// when the workspace reached running-with-connected-agent.
    func start(
        server: CoderServer,
        token: String,
        workspaceID: UUID,
        agentID: UUID?
    ) async -> CoderStartFailure? {
        reset()
        do {
            let detail = try await fetchWorkspace(server: server, token: token, workspaceID: workspaceID)
            if detail.isDormant {
                phase = .failed(.workspaceDormant)
                return .workspaceDormant
            }
        } catch let failure {
            phase = .failed(failure)
            return failure
        }
        appendLog("checking startup parameters")
        phase = .checkingParameters
        if await autostartBlocked(server: server, token: token, workspaceID: workspaceID) {
            appendLog("parameter mismatch — refusing to answer parameters")
            phase = .failed(.parameterMismatch)
            return .parameterMismatch
        }

        appendLog("posting start request (reason: ssh_connection)")
        phase = .starting
        let postResult = await postStart(server: server, token: token, workspaceID: workspaceID)
        switch postResult {
        case .accepted:
            appendLog("start accepted")
        case .alreadyInFlight:
            appendLog("ambiguous POST resolved: server already accepted a start build")
        case .failure(let failure):
            appendLog("start failed: \(failure.title)")
            phase = .failed(failure)
            return failure
        }

        return await followUntilReady(
            server: server,
            token: token,
            workspaceID: workspaceID,
            agentID: agentID
        )
    }

    private enum PostOutcome {
        case accepted
        case alreadyInFlight
        case failure(CoderStartFailure)
    }

    private func postStart(
        server: CoderServer,
        token: String,
        workspaceID: UUID
    ) async -> PostOutcome {
        var request = URLRequest(
            url: server.baseURL.appendingPathComponent("api/v2/workspaces/\(workspaceID.uuidString.lowercased())/builds")
        )
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let transition = "start"
            let reason = "ssh_connection"
        }
        request.httpBody = try? JSONEncoder().encode(Body())

        let response: CoderHTTPResponse
        do {
            startPosts += 1
            response = try await perform(request)
        } catch {
            // Spec §6.1: a network failure after a start POST is ambiguous —
            // fetch the latest build before any retry so an accepted start is
            // never duplicated.
            if let detail = try? await fetchWorkspace(server: server, token: token, workspaceID: workspaceID),
               detail.latestBuild.transition == "start",
               ["pending", "starting", "running"].contains(detail.latestBuild.status) {
                return .alreadyInFlight
            }
            return .failure(.startAmbiguous)
        }
        switch response.statusCode {
        case 200..<300:
            return .accepted
        case 401, 403:
            return .failure(.unauthorized)
        default:
            return .failure(.startRejected(statusCode: response.statusCode))
        }
    }

    private func autostartBlocked(
        server: CoderServer,
        token: String,
        workspaceID: UUID
    ) async -> Bool {
        var request = URLRequest(
            url: server.baseURL.appendingPathComponent(
                "api/v2/workspaces/\(workspaceID.uuidString.lowercased())/resolve-autostart"
            )
        )
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        guard let response = await performIgnoringErrors(request),
              response.statusCode == 200 else {
            return false
        }
        struct Answer: Decodable {
            let parameterMismatch: Bool?

            private enum CodingKeys: String, CodingKey {
                case parameterMismatch = "parameter_mismatch"
            }
        }
        return (try? JSONDecoder().decode(Answer.self, from: response.body))?.parameterMismatch == true
    }

    /// Spec §6.2 layered readiness: the start build must complete AND an
    /// agent must report connected. Bounded by ``startupDeadline``.
    private func followUntilReady(
        server: CoderServer,
        token: String,
        workspaceID: UUID,
        agentID: UUID?
    ) async -> CoderStartFailure? {
        let deadline = Date().addingTimeInterval(Self.startupDeadline)
        while Date() < deadline {
            let detail: CoderWorkspaceDetail
            do {
                detail = try await fetchWorkspace(server: server, token: token, workspaceID: workspaceID)
            } catch let failure {
                appendLog("readiness check failed: \(failure.title)")
                phase = .failed(failure)
                return failure
            }

            if detail.isRunning {
                let agents = detail.latestBuild.agents
                let agent: CoderWorkspaceAgent?
                if let agentID {
                    agent = agents.first { $0.id == agentID }
                } else if agents.count == 1 {
                    agent = agents.first
                } else {
                    phase = .failed(.agentSelectionRequired)
                    return .agentSelectionRequired
                }
                guard let agent else {
                    phase = .failed(.agentSelectionRequired)
                    return .agentSelectionRequired
                }

                let lifecycle = detail.latestBuild.agentLifecycles[agent.id] ?? "unknown"
                if ["start_error", "start_timeout", "shutdown_error", "shutdown_timeout"].contains(lifecycle) {
                    await appendAgentLogs(server: server, token: token, agentID: agent.id)
                    phase = .failed(.agentStartupFailed(state: lifecycle))
                    return .agentStartupFailed(state: lifecycle)
                }
                if agent.isConnected, !agent.blocksLoginUntilReady || lifecycle == "ready" {
                    appendLog("build running, agent connected, lifecycle \(lifecycle)")
                    phase = .ready
                    return nil
                }
                let state = "\(agent.status) · \(lifecycle)"
                if phase != .waitingForAgent(state) {
                    appendLog("build running, waiting for agent (\(state))")
                }
                phase = .waitingForAgent(state)
            } else {
                let status = detail.latestBuild.status
                if ["failed", "canceled", "deleted"].contains(status) {
                    appendLog("build ended in \(status)")
                    phase = .failed(.buildFailed(status: status))
                    return .buildFailed(status: status)
                }
                if phase != .waitingForBuild(status) {
                    appendLog("build \(status)")
                }
                phase = .waitingForBuild(status)
            }

            do {
                try await Task.sleep(nanoseconds: Self.pollInterval)
            } catch {
                return .serverUnreachable
            }
        }
        appendLog("deadline exceeded (10 min)")
        phase = .failed(.deadlineExceeded)
        return .deadlineExceeded
    }

    private func appendAgentLogs(server: CoderServer, token: String, agentID: UUID) async {
        let logsURL = server.baseURL.appendingPathComponent(
            "api/v2/workspaceagents/\(agentID.uuidString.lowercased())/logs"
        )
        guard var components = URLComponents(url: logsURL, resolvingAgainstBaseURL: false) else {
            appendLog("agent logs unavailable")
            return
        }
        components.queryItems = [URLQueryItem(name: "after", value: "0")]
        guard let url = components.url else {
            appendLog("agent logs unavailable")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        guard let response = await performIgnoringErrors(request), response.statusCode == 200 else {
            appendLog("agent logs unavailable")
            return
        }
        struct AgentLog: Decodable { let output: String }
        guard let records = try? JSONDecoder().decode([AgentLog].self, from: response.body) else {
            appendLog("agent logs unavailable")
            return
        }
        for record in records.suffix(20) {
            appendLog("agent: \(record.output)")
        }
    }

    // MARK: - Request plumbing

    private func perform(_ request: URLRequest) async throws(CoderStartFailure) -> CoderHTTPResponse {
        do {
            return try await loader.load(request)
        } catch {
            throw .serverUnreachable
        }
    }

    private func performIgnoringErrors(_ request: URLRequest) async -> CoderHTTPResponse? {
        do {
            return try await loader.load(request)
        } catch {
            return nil
        }
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logTrail.append("\(formatter.string(from: Date()))  \(line)")
        if logTrail.count > 60 {
            logTrail.removeFirst(logTrail.count - 60)
        }
    }
}
