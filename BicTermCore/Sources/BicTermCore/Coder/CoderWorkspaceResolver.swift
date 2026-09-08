import Foundation

/// A fully resolved coder session target: control-plane endpoint plus the
/// selected agent identity, ready to hand to the tunnel bridge config.
public struct CoderAgentEndpoint: Sendable, Equatable {
    public let serverURL: URL
    public let sessionToken: String
    public let agentID: UUID

    public init(serverURL: URL, sessionToken: String, agentID: UUID) {
        self.serverURL = serverURL
        self.sessionToken = sessionToken
        self.agentID = agentID
    }
}

/// Typed failures of workspace/agent resolution. Each class maps to exactly
/// one ``TransportError`` case at the transport boundary; the vocabulary
/// separates credential failure (reauthenticate) from stale session identity
/// (re-resolve and reconnect) from transient reachability (retry).
public enum CoderResolutionError: Error, Equatable, Sendable {
    /// The connection's `serverID` matches no stored server configuration.
    case serverUnknown
    /// No usable token exists for the server's Keychain tag.
    case tokenMissing
    /// The server rejected the credential (HTTP 401/403).
    case unauthorized
    /// The server could not be queried (network, TLS, 5xx, rate limit,
    /// malformed payload).
    case serverUnreachable
    /// The workspace UUID is absent from the owner's listing.
    case workspaceMissing
    /// The workspace's latest build is not `running` (spec §6.2 build layer).
    case workspaceNotRunning(state: CoderWorkspaceState)
    /// No single eligible connected agent exists (zero, or ambiguous
    /// multiple candidates — spec §5.2 never picks silently).
    case agentUnavailable
}

/// Resolves a persisted ``CoderReference`` to a dialable
/// ``CoderAgentEndpoint`` through the REST layer (spec §13's
/// WorkspaceResolver, MVP scope: current owner listing + single-agent
/// auto-selection; startup policy and wait loops are deliberate exclusions).
public struct CoderWorkspaceResolver: Sendable {
    private let serverStore: any CoderServerStoreProtocol
    private let tokenStore: any CoderTokenStoring
    private let client: CoderClient

    public init(
        serverStore: any CoderServerStoreProtocol,
        tokenStore: any CoderTokenStoring,
        requestLoader: any CoderRequestLoading = SystemCoderRequestLoader()
    ) {
        self.serverStore = serverStore
        self.tokenStore = tokenStore
        self.client = CoderClient(tokenStore: tokenStore, requestLoader: requestLoader)
    }

    public func resolve(_ reference: CoderReference) async throws(CoderResolutionError) -> CoderAgentEndpoint {
        let server: CoderServer
        do {
            guard let stored = try await serverStore.coderServer(id: reference.serverID) else {
                throw CoderResolutionError.serverUnknown
            }
            server = stored
        } catch let error as CoderResolutionError {
            throw error
        } catch {
            throw .serverUnreachable
        }

        let token: String?
        do {
            token = try await tokenStore.token(for: server.tokenKeychainTag)
        } catch {
            throw .tokenMissing
        }
        guard let token, !token.isEmpty else { throw .tokenMissing }

        let workspaces: [CoderWorkspace]
        do {
            workspaces = try await client.workspaces(for: server)
        } catch let error as CoderClientError {
            throw Self.transportMapping(error)
        }

        guard let workspace = workspaces.first(where: { $0.id == reference.workspaceID }) else {
            throw .workspaceMissing
        }
        guard workspace.state == .running else {
            throw .workspaceNotRunning(state: workspace.state)
        }
        let connected = workspace.agents.filter(\.isConnected)
        guard connected.count == 1, let agent = connected.first else {
            throw .agentUnavailable
        }
        return CoderAgentEndpoint(
            serverURL: server.baseURL,
            sessionToken: token,
            agentID: agent.id
        )
    }

    private static func transportMapping(_ error: CoderClientError) -> CoderResolutionError {
        switch error {
        case .unauthorized, .forbidden:
            .unauthorized
        case .tokenStorageFailure:
            .tokenMissing
        case .rateLimited, .serverError, .unexpectedStatusCode, .invalidURL,
             .tlsFailure, .networkFailure, .malformedResponse, .requestCancelled:
            .serverUnreachable
        }
    }
}
