import Darwin
import Foundation

public struct SpikeHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
}

public struct LoopbackAgentConnectionClient: Sendable {
    public init() {}

    public func fetch(_ request: URLRequest) throws(TailnetSpikeError) -> AgentConnectionInfo {
        let response = try LoopbackHTTPClient().get(request)
        guard response.statusCode == 200 else {
            throw .unexpectedHTTPStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(AgentConnectionInfo.self, from: response.body)
        } catch {
            throw .malformedHTTPResponse
        }
    }
}

struct LoopbackHTTPClient {
    func get(_ request: URLRequest) throws(TailnetSpikeError) -> SpikeHTTPResponse {
        guard let url = request.url,
              url.scheme == "http",
              let host = url.host,
              Self.isLoopback(host),
              let port = url.port else {
            throw .unsupportedProbeTransport
        }

        let socket = try LoopbackSocket(host: host, port: port)
        defer { socket.close() }
        try socket.write(Self.serializedRequest(request, connection: "close"))
        let head = try socket.readHTTPHead()
        let parsed = try Self.parseHTTPHead(head)
        guard let rawContentLength = parsed.headers["content-length"],
              let contentLength = Int(rawContentLength),
              (0...1_048_576).contains(contentLength) else {
            throw .malformedHTTPResponse
        }
        let body = try socket.readExactly(contentLength)
        return SpikeHTTPResponse(statusCode: parsed.statusCode, headers: parsed.headers, body: body)
    }

    static func serializedRequest(_ request: URLRequest, connection: String) -> Data {
        let url = request.url!
        var lines = [
            "\(request.httpMethod ?? "GET") \(requestTarget(url)) HTTP/1.1",
            "Host: \(url.host!):\(url.port!)",
            "Connection: \(connection)",
        ]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func requestTarget(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        guard let query = components?.percentEncodedQuery, !query.isEmpty else { return path }
        return "\(path)?\(query)"
    }

    static func parseHTTPHead(_ data: Data) throws(TailnetSpikeError) -> (statusCode: Int, headers: [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else { throw .malformedHTTPResponse }
        let lines = text.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw .malformedHTTPResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw .malformedHTTPResponse }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (statusCode, headers)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame || host == "127.0.0.1"
    }
}

final class LoopbackSocket {
    private var descriptor: Int32
    private var buffered = Data()

    init(host: String, port: Int) throws(TailnetSpikeError) {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .connectionFailed }

        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let numericHost = host.caseInsensitiveCompare("localhost") == .orderedSame ? "127.0.0.1" : host
        guard inet_pton(AF_INET, numericHost, &address.sin_addr) == 1 else {
            close()
            throw .connectionFailed
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close()
            throw .connectionFailed
        }
    }

    deinit {
        close()
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func write(_ data: Data) throws(TailnetSpikeError) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            guard written > 0 else { throw .writeFailed }
            offset += written
        }
    }

    func readHTTPHead() throws(TailnetSpikeError) -> Data {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffered.range(of: separator) {
                let header = buffered[..<range.lowerBound]
                let remainder = buffered[range.upperBound...]
                buffered = Data(remainder)
                return Data(header)
            }
            guard buffered.count < 65_536 else { throw .malformedHTTPResponse }
            buffered.append(try readChunk())
        }
    }

    func readExactly(_ count: Int) throws(TailnetSpikeError) -> Data {
        guard count >= 0 else { throw .readFailed }
        var result = Data()
        while result.count < count {
            if buffered.isEmpty {
                buffered.append(try readChunk())
            }
            let consumedCount = min(count - result.count, buffered.count)
            result.append(buffered.prefix(consumedCount))
            buffered.removeFirst(consumedCount)
        }
        return result
    }

    private func readChunk() throws(TailnetSpikeError) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.recv(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count > 0 else { throw .readFailed }
        return Data(bytes.prefix(count))
    }
}
