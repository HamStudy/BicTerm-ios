import Foundation

public struct CoderServer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let tokenKeychainTag: String

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        tokenKeychainTag: String
    ) throws(CoderServerValidationError) {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw .httpsRequired
        }
        guard baseURL.host != nil else {
            throw .hostRequired
        }
        guard baseURL.user == nil, baseURL.password == nil else {
            throw .embeddedCredentialsNotAllowed
        }

        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.tokenKeychainTag = tokenKeychainTag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            baseURL: container.decode(URL.self, forKey: .baseURL),
            tokenKeychainTag: container.decode(String.self, forKey: .tokenKeychainTag)
        )
    }
}
