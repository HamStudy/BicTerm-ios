import CryptoKit
import Foundation

public enum CoordinateProbeResult: Equatable, Sendable {
    case upgraded(binaryPayload: Data)
    case rejected(statusCode: Int)
}

public enum WebSocketHandshake {
    public static func accept(for key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }
}

public struct CoordinateWebSocketProbe: Sendable {
    private static let fixtureKey = "dGhlIHNhbXBsZSBub25jZQ=="

    public init() {}

    public func connect(_ request: URLRequest) throws(TailnetSpikeError) -> CoordinateProbeResult {
        guard let url = request.url,
              url.scheme == "ws",
              let host = url.host,
              (host == "127.0.0.1" || host.caseInsensitiveCompare("localhost") == .orderedSame),
              let port = url.port else {
            throw .unsupportedProbeTransport
        }

        let socket = try LoopbackSocket(host: host, port: port)
        defer { socket.close() }
        try socket.write(handshakeRequest(request))
        let head = try socket.readHTTPHead()
        let parsed = try LoopbackHTTPClient.parseHTTPHead(head)
        guard parsed.statusCode == 101 else {
            return .rejected(statusCode: parsed.statusCode)
        }

        guard parsed.headers["upgrade"]?.lowercased() == "websocket",
              parsed.headers["connection"]?.lowercased().contains("upgrade") == true,
              parsed.headers["sec-websocket-accept"] == WebSocketHandshake.accept(for: Self.fixtureKey) else {
            throw .invalidWebSocketUpgrade
        }
        return .upgraded(binaryPayload: try readBinaryFrame(from: socket))
    }

    private func handshakeRequest(_ request: URLRequest) -> Data {
        let url = request.url!
        var lines = [
            "GET \(LoopbackHTTPClient.requestTarget(url)) HTTP/1.1",
            "Host: \(url.host!):\(url.port!)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(Self.fixtureKey)",
            "Sec-WebSocket-Version: 13",
        ]
        if let token = request.value(forHTTPHeaderField: "Coder-Session-Token") {
            lines.append("Coder-Session-Token: \(token)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func readBinaryFrame(from socket: LoopbackSocket) throws(TailnetSpikeError) -> Data {
        let first = try socket.readExactly(2)
        guard first[0] & 0x80 != 0, first[0] & 0x0F == 0x02, first[1] & 0x80 == 0 else {
            throw .invalidWebSocketFrame
        }

        let shortLength = Int(first[1] & 0x7F)
        switch shortLength {
        case 0...125:
            return try socket.readExactly(shortLength)
        default:
            throw .invalidWebSocketFrame
        }
    }
}
