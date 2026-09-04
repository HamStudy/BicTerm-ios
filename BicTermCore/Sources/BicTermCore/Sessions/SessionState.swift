import Foundation

/// Per-session lifecycle states. `closed` is terminal; `failed` is the
/// actionable UI state (manual `reconnect` retries from it).
/// `suspended` == the plan's `.reconnectRequired`: backgrounded or
/// restored-from-snapshot sessions NEVER auto-connect.
public enum SessionState: Equatable, Sendable {
    case connecting
    case active
    case disconnected
    case reconnecting
    case suspended
    case failed(SessionFailure)
    case closed
}

public enum SessionFailure: Error, Equatable, Sendable {
    case transport(SessionTransportError)
    case reconnectAttemptsExhausted(attempts: Int, lastError: SessionTransportError)
    case persistence(PersistenceError)
}

extension SessionFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .transport(error):
            error.localizedDescription
        case let .reconnectAttemptsExhausted(attempts, lastError):
            "Reconnect failed after \(attempts) attempts: \(lastError.localizedDescription)"
        case let .persistence(error):
            error.localizedDescription
        }
    }
}

public enum SessionRegistryError: Error, Equatable, Sendable {
    /// A live or suspended session already owns this sceneID (one session
    /// per scene; `closeSession` first).
    case sceneOccupied(sceneID: String)
    case noSession(sceneID: String)
    case sessionClosed(sceneID: String)
    /// The operation is not valid for the session's current state.
    case invalidTransition(sceneID: String, state: SessionState)
    case transport(SessionTransportError)
    case persistence(PersistenceError)
}

extension SessionRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .sceneOccupied(sceneID):
            "Scene \(sceneID) already has a session."
        case let .noSession(sceneID):
            "No session exists for scene \(sceneID)."
        case let .sessionClosed(sceneID):
            "The session for scene \(sceneID) is closed."
        case let .invalidTransition(sceneID, state):
            "Operation is not valid for scene \(sceneID) in state \(state)."
        case let .transport(error):
            error.localizedDescription
        case let .persistence(error):
            error.localizedDescription
        }
    }
}
