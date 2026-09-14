import Foundation

public struct Hop: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let offersKeys: Bool
    public let customKeys: [String]?
    public let passwordTag: String?

    public init(
        host: String,
        port: Int,
        username: String,
        offersKeys: Bool = true,
        customKeys: [String]? = nil,
        passwordTag: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.offersKeys = offersKeys
        self.customKeys = customKeys
        self.passwordTag = passwordTag == "" ? nil : passwordTag
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, username, keyReference, authMethod, offersKeys, customKeys, passwordTag
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(offersKeys, forKey: .offersKeys)
        try container.encodeIfPresent(customKeys, forKey: .customKeys)
        try container.encodeIfPresent(passwordTag, forKey: .passwordTag)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        if container.contains(.offersKeys) || container.contains(.customKeys) || container.contains(.passwordTag) {
            offersKeys = try container.decodeIfPresent(Bool.self, forKey: .offersKeys) ?? true
            customKeys = try container.decodeIfPresent([String].self, forKey: .customKeys)
            let decodedTag = try container.decodeIfPresent(String.self, forKey: .passwordTag)
            passwordTag = decodedTag == "" ? nil : decodedTag
        } else {
            let legacyKey = try container.decode(String.self, forKey: .keyReference)
            let method = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .publickey
            offersKeys = method == .publickey
            customKeys = method == .publickey ? (legacyKey.isEmpty ? [] : [legacyKey]) : nil
            passwordTag = method == .password && !legacyKey.isEmpty ? legacyKey : nil
        }
    }
}
