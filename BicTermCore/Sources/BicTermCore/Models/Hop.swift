import Foundation

public struct Hop: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let keyReference: String

    public init(host: String, port: Int, username: String, keyReference: String) {
        self.host = host
        self.port = port
        self.username = username
        self.keyReference = keyReference
    }
}
