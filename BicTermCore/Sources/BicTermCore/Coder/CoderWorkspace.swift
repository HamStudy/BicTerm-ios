import Foundation

public enum CoderWorkspaceState: Equatable, Hashable, Sendable {
    case pending
    case starting
    case running
    case stopping
    case stopped
    case failed
    case canceling
    case canceled
    case deleting
    case deleted
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "pending": self = .pending
        case "starting": self = .starting
        case "running": self = .running
        case "stopping": self = .stopping
        case "stopped": self = .stopped
        case "failed": self = .failed
        case "canceling": self = .canceling
        case "canceled": self = .canceled
        case "deleting": self = .deleting
        case "deleted": self = .deleted
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .failed: "failed"
        case .canceling: "canceling"
        case .canceled: "canceled"
        case .deleting: "deleting"
        case .deleted: "deleted"
        case let .unknown(value): value
        }
    }

    public var isConnectable: Bool {
        self == .running
    }
}

extension CoderWorkspaceState: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An agent of a workspace's latest build (spec §5.1): identity for the
/// tunnel dial (the agent UUID feeds `DialAgent`, never a template preview).
public struct CoderWorkspaceAgent: Decodable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// Raw upstream `status` (`connected`/`connecting`/`disconnected`/`timeout`,
    /// possibly a newer value); only `connected` makes the agent dialable.
    public let status: String

    public var isConnected: Bool {
        status.lowercased() == "connected"
    }
}

public struct CoderWorkspace: Decodable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let ownerName: String
    public let state: CoderWorkspaceState
    /// Agents from the latest build's resources; empty for responses that
    /// predate per-resource agents and for snapshot-only constructions.
    public let agents: [CoderWorkspaceAgent]

    public var isConnectable: Bool {
        state.isConnectable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerName = "owner_name"
        case latestBuild = "latest_build"
    }

    private struct LatestBuild: Decodable {
        let status: String?
        let resources: [Resource]?
    }

    private struct Resource: Decodable {
        let agents: [CoderWorkspaceAgent]?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        let latestBuild = try container.decodeIfPresent(LatestBuild.self, forKey: .latestBuild)
        state = CoderWorkspaceState(rawValue: latestBuild?.status ?? "")
        agents = (latestBuild?.resources ?? []).flatMap { $0.agents ?? [] }
    }

    public init(
        stateOnly id: UUID,
        name: String,
        ownerName: String,
        state: CoderWorkspaceState
    ) {
        self.id = id
        self.name = name
        self.ownerName = ownerName
        self.state = state
        self.agents = []
    }
}
