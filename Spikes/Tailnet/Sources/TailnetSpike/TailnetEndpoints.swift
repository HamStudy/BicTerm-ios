import Foundation

public enum TailnetSpikeError: Error, Equatable, Sendable {
    case invalidBaseURL
    case insecureBaseURL
    case missingToken
    case unsupportedProbeTransport
    case connectionFailed
    case writeFailed
    case readFailed
    case malformedHTTPResponse
    case unexpectedHTTPStatus(Int)
    case invalidWebSocketUpgrade
    case invalidWebSocketFrame
}

public struct TailnetEndpoints: Equatable, Sendable {
    public let connectionURL: URL
    public let coordinateURL: URL

    public init(
        baseURL: URL,
        agentID: UUID,
        allowsInsecureLoopback: Bool = false
    ) throws(TailnetSpikeError) {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host,
              baseURL.user == nil,
              baseURL.password == nil else {
            throw .invalidBaseURL
        }

        let webSocketScheme: String
        switch scheme {
        case "https":
            webSocketScheme = "wss"
        case "http" where allowsInsecureLoopback && Self.isLoopback(host):
            webSocketScheme = "ws"
        case "http":
            throw .insecureBaseURL
        default:
            throw .invalidBaseURL
        }

        let agentPath = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent("workspaceagents")
            .appendingPathComponent(agentID.uuidString.lowercased())
        connectionURL = agentPath.appendingPathComponent("connection")

        guard var coordinateComponents = URLComponents(
            url: agentPath.appendingPathComponent("coordinate"),
            resolvingAgainstBaseURL: false
        ) else {
            throw .invalidBaseURL
        }
        coordinateComponents.scheme = webSocketScheme
        coordinateComponents.queryItems = [URLQueryItem(name: "version", value: "2.0")]
        guard let coordinateURL = coordinateComponents.url else { throw .invalidBaseURL }
        self.coordinateURL = coordinateURL
    }

    public func connectionRequest(token: String) throws(TailnetSpikeError) -> URLRequest {
        guard !token.isEmpty else { throw .missingToken }
        var request = URLRequest(url: connectionURL)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        return request
    }

    public func coordinateRequest(token: String?) throws(TailnetSpikeError) -> URLRequest {
        if let token, token.isEmpty { throw .missingToken }
        var request = URLRequest(url: coordinateURL)
        request.httpMethod = "GET"
        if let token {
            request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        }
        return request
    }

    private static func isLoopback(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame || host == "127.0.0.1"
    }
}
