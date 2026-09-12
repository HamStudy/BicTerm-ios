import Foundation

public enum ConnectionType: String, Codable, Equatable, Hashable, Sendable {
    case ssh
    /// Test-backed proof that a non-SSH protocol can traverse persistence and
    /// registry resolution. No production factory registers this protocol.
    case uppercaseEcho = "uppercase-echo"
}

/// How SSH user authentication proceeds for a connection destination or a
/// single jump host. The credential bytes are NEVER part of the model: for
/// `.publickey` the `keyReference` names a private key in the key stores; for
/// `.password` it carries an opaque Keychain tag resolvable only through the
/// password store. Servers must allow password authentication; NIOSSH
/// implements the RFC 4252 `password` method only (no keyboard-interactive),
/// so sshd needs `PasswordAuthentication yes` (the OpenSSH default).
public enum AuthMethod: String, Codable, Equatable, Hashable, Sendable {
    case publickey
    case password
}

public struct Connection: Codable, Equatable, Identifiable, Sendable {
    public static let maximumJumpChainLength = 5

    public let id: UUID
    public let name: String
    public let type: ConnectionType
    public let host: String
    public let port: Int
    public let username: String
    /// Credential reference: a key-store reference when `authMethod` is
    /// `.publickey`, an opaque Keychain password tag when it is `.password`.
    /// Never credential bytes themselves.
    public let keyReference: String
    public let authMethod: AuthMethod
    public let jumpChain: [Hop]
    public let protocolOptions: ProtocolOptions

    public init(
        id: UUID = UUID(),
        name: String,
        type: ConnectionType,
        host: String,
        port: Int,
        username: String,
        keyReference: String,
        authMethod: AuthMethod = .publickey,
        jumpChain: [Hop] = [],
        protocolOptions: ProtocolOptions = ProtocolOptions()
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
        self.authMethod = authMethod
        self.jumpChain = jumpChain
        self.protocolOptions = protocolOptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            // Strict on purpose: payloads written by removed features carry
            // protocol ids this build no longer ships. The store quarantines
            // those rows (load skips them) instead of failing wholesale.
            type: container.decode(ConnectionType.self, forKey: .type),
            host: container.decode(String.self, forKey: .host),
            port: container.decode(Int.self, forKey: .port),
            username: container.decode(String.self, forKey: .username),
            keyReference: container.decode(String.self, forKey: .keyReference),
            // Backward compatibility: payloads written before password
            // support carry no authMethod and always meant key auth.
            authMethod: container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .publickey,
            jumpChain: container.decode([Hop].self, forKey: .jumpChain),
            protocolOptions: container.decode(ProtocolOptions.self, forKey: .protocolOptions)
        )
    }

    /// Per-connection herdr toggle over ``ProtocolOptions/herdrEnabled``.
    public var herdrEnabled: Bool {
        protocolOptions.herdrEnabled
    }

    /// Trimmed remote herdr session name over ``ProtocolOptions/herdrSessionName``;
    /// nil when unset, blank, or wrong-typed.
    public var herdrSessionName: String? {
        protocolOptions.herdrSessionName
    }
}
