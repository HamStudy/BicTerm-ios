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
    public let offersKeys: Bool
    public let customKeys: [String]?
    public let passwordTag: String?
    public let jumpChain: [Hop]
    public let protocolOptions: ProtocolOptions
    /// Optional command line (e.g. `tmux new-session -A -s main`) sent as
    /// terminal input when the session's shell comes up — on first connect
    /// and every reconnect — to create-or-reattach a persistent multiplexer
    /// session. Never a protocol option: `protocolOptions.values` is copied
    /// wholesale onto herd paths, which must stay free of terminal-shell
    /// behavior.
    public let startupCommand: String?

    public init(
        id: UUID = UUID(),
        name: String,
        type: ConnectionType,
        host: String,
        port: Int,
        username: String,
        offersKeys: Bool = true,
        customKeys: [String]? = nil,
        passwordTag: String? = nil,
        jumpChain: [Hop] = [],
        protocolOptions: ProtocolOptions = ProtocolOptions(),
        startupCommand: String? = nil
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
        self.offersKeys = offersKeys
        self.customKeys = customKeys
        self.passwordTag = passwordTag == "" ? nil : passwordTag
        self.jumpChain = jumpChain
        self.protocolOptions = protocolOptions
        self.startupCommand = startupCommand == "" ? nil : startupCommand
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, username, keyReference, authMethod
        case jumpChain, protocolOptions, offersKeys, customKeys, passwordTag
        case startupCommand
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(jumpChain, forKey: .jumpChain)
        try container.encode(protocolOptions, forKey: .protocolOptions)
        try container.encode(offersKeys, forKey: .offersKeys)
        try container.encodeIfPresent(customKeys, forKey: .customKeys)
        try container.encodeIfPresent(passwordTag, forKey: .passwordTag)
        try container.encodeIfPresent(startupCommand, forKey: .startupCommand)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let offersKeys: Bool
        let customKeys: [String]?
        let passwordTag: String?
        if container.contains(.offersKeys) || container.contains(.customKeys) || container.contains(.passwordTag) {
            offersKeys = try container.decodeIfPresent(Bool.self, forKey: .offersKeys) ?? true
            customKeys = try container.decodeIfPresent([String].self, forKey: .customKeys)
            passwordTag = try container.decodeIfPresent(String.self, forKey: .passwordTag)
        } else {
            let legacyKey = try container.decode(String.self, forKey: .keyReference)
            let method = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .publickey
            offersKeys = method == .publickey
            customKeys = method == .publickey ? (legacyKey.isEmpty ? [] : [legacyKey]) : nil
            passwordTag = method == .password ? legacyKey : nil
        }
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
            offersKeys: offersKeys,
            customKeys: customKeys,
            passwordTag: passwordTag,
            jumpChain: container.decode([Hop].self, forKey: .jumpChain),
            protocolOptions: container.decode(ProtocolOptions.self, forKey: .protocolOptions),
            // Legacy payloads predate the key: absent decodes as nil. Wrong-
            // typed junk fails the row (typed throw), matching passwordTag.
            startupCommand: container.decodeIfPresent(String.self, forKey: .startupCommand)
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
