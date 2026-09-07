import Foundation

public struct Hop: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    /// Credential reference: key-store reference for `.publickey`, Keychain
    /// password tag for `.password`. Never credential bytes.
    public let keyReference: String
    public let authMethod: AuthMethod

    public init(
        host: String,
        port: Int,
        username: String,
        keyReference: String,
        authMethod: AuthMethod = .publickey
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.keyReference = keyReference
        self.authMethod = authMethod
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        keyReference = try container.decode(String.self, forKey: .keyReference)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .publickey
    }
}
