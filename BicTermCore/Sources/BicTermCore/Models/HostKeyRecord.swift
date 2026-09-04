import Foundation

public enum HostKeyTrustState: String, Codable, Equatable, Hashable, Sendable {
    case trusted
    case firstSeen
}

public struct HostKeyIdentity: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var persistenceKey: String {
        "\(host.utf8.count):\(host):\(port)"
    }
}

public struct HostKeyRecord: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let algorithm: String
    public let publicKeyData: Data
    public let trustState: HostKeyTrustState
    public let firstSeenDate: Date

    public init(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyData: Data,
        trustState: HostKeyTrustState,
        firstSeenDate: Date
    ) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.publicKeyData = publicKeyData
        self.trustState = trustState
        self.firstSeenDate = firstSeenDate
    }

    public var identity: HostKeyIdentity {
        HostKeyIdentity(host: host, port: port)
    }
}
