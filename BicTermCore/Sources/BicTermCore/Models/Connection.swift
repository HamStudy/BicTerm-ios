import Foundation

public enum ConnectionType: String, Codable, Equatable, Hashable, Sendable {
    case ssh
    case coder
    /// Test-backed proof that a non-SSH protocol can traverse persistence and
    /// registry resolution. No production factory registers this protocol.
    case uppercaseEcho = "uppercase-echo"
}

public struct CoderReference: Codable, Equatable, Hashable, Sendable {
    public let serverID: UUID
    public let workspaceID: UUID

    public init(serverID: UUID, workspaceID: UUID) {
        self.serverID = serverID
        self.workspaceID = workspaceID
    }
}

public struct Connection: Codable, Equatable, Identifiable, Sendable {
    public static let maximumJumpChainLength = 5

    public let id: UUID
    public let name: String
    public let type: ConnectionType
    public let host: String
    public let port: Int
    public let username: String
    public let keyReference: String
    public let jumpChain: [Hop]
    public let protocolOptions: ProtocolOptions
    public let coderRef: CoderReference?

    public init(
        id: UUID = UUID(),
        name: String,
        type: ConnectionType,
        host: String,
        port: Int,
        username: String,
        keyReference: String,
        jumpChain: [Hop] = [],
        protocolOptions: ProtocolOptions = ProtocolOptions(),
        coderRef: CoderReference? = nil
    ) throws(ConnectionValidationError) {
        guard jumpChain.count <= Self.maximumJumpChainLength else {
            throw .jumpChainTooLong(
                maximum: Self.maximumJumpChainLength,
                actual: jumpChain.count
            )
        }

        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.keyReference = keyReference
        self.jumpChain = jumpChain
        self.protocolOptions = protocolOptions
        self.coderRef = coderRef
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            type: container.decode(ConnectionType.self, forKey: .type),
            host: container.decode(String.self, forKey: .host),
            port: container.decode(Int.self, forKey: .port),
            username: container.decode(String.self, forKey: .username),
            keyReference: container.decode(String.self, forKey: .keyReference),
            jumpChain: container.decode([Hop].self, forKey: .jumpChain),
            protocolOptions: container.decode(ProtocolOptions.self, forKey: .protocolOptions),
            coderRef: container.decodeIfPresent(CoderReference.self, forKey: .coderRef)
        )
    }
}
