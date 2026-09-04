import Foundation

public enum SessionSnapshotState: String, Codable, Equatable, Hashable, Sendable {
    case reconnectRequired
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let sceneID: String
    public let state: SessionSnapshotState
    public let createdAt: Date

    public init(
        connectionID: UUID,
        sceneID: String,
        state: SessionSnapshotState = .reconnectRequired,
        createdAt: Date = Date()
    ) {
        self.connectionID = connectionID
        self.sceneID = sceneID
        self.state = state
        self.createdAt = createdAt
    }
}
