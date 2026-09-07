import Darwin
import Foundation
import TailnetSpike

@main
struct TailnetFixtureCommand {
    static func main() {
        do {
            signal(SIGPIPE, SIG_IGN)
            let arguments = try Arguments.parse(CommandLine.arguments)
            let payload = try Data(contentsOf: arguments.fixtureURL)
            _ = try JSONDecoder().decode(AgentConnectionInfo.self, from: payload)
            let server = try FixtureServer(port: arguments.port, fixturePayload: payload, logURL: arguments.logURL)
            print("tailnet-fixture listening on 127.0.0.1:\(arguments.port)")
            try server.run()
        } catch {
            FileHandle.standardError.write(Data("tailnet-fixture FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
}

private struct Arguments {
    let port: Int
    let fixtureURL: URL
    let logURL: URL
    let allowedRootURL: URL

    static func parse(_ arguments: [String]) throws -> Arguments {
        var port: Int?
        var fixtureURL: URL?
        var logURL: URL?
        var allowedRootURL: URL?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw FixtureError.invalidArguments }
            switch arguments[index] {
            case "--port": port = Int(arguments[index + 1])
            case "--fixture": fixtureURL = URL(fileURLWithPath: arguments[index + 1])
            case "--log": logURL = URL(fileURLWithPath: arguments[index + 1])
            case "--allowed-root": allowedRootURL = URL(fileURLWithPath: arguments[index + 1])
            default: throw FixtureError.invalidArguments
            }
            index += 2
        }
        guard let port, (1...65_535).contains(port), let fixtureURL, let logURL, let allowedRootURL,
              contains(fixtureURL, within: allowedRootURL),
              contains(logURL, within: allowedRootURL) else {
            throw FixtureError.invalidArguments
        }
        return Arguments(port: port, fixtureURL: fixtureURL, logURL: logURL, allowedRootURL: allowedRootURL)
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate: String
        if FileManager.default.fileExists(atPath: candidate.path) {
            resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        } else {
            resolvedCandidate = candidate.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(candidate.lastPathComponent)
                .path
        }
        return resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }
}

private final class FixtureServer {
    private let listener: Int32
    private let fixturePayload: Data
    private let logURL: URL
    private let validToken = "fixture-token"
    private let coordinatePayload = Data("fixture-coordinate-binary".utf8)
    private let webSocketKey = "dGhlIHNhbXBsZSBub25jZQ=="
    private let webSocketAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    init(port: Int, fixturePayload: Data, logURL: URL) throws {
        self.fixturePayload = fixturePayload
        self.logURL = logURL
        try Data().write(to: logURL)

        listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw FixtureError.socketFailure }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 16) == 0 else {
            Darwin.close(listener)
            throw FixtureError.socketFailure
        }
    }

    deinit {
        Darwin.close(listener)
    }

    func run() throws {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw FixtureError.socketFailure
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        do {
            let request = try readRequest(client)
            let auth = authenticationLabel(request.headers["coder-session-token"])
            if request.path.hasSuffix("/connection") {
                guard auth == "valid" else {
                    try sendJSON(client, status: 401, body: #"{"message":"invalid api key"}"#)
                    appendLog("REST connection auth=\(auth) status=401")
                    return
                }
                try sendResponse(client, status: "200 OK", contentType: "application/json", body: fixturePayload)
                appendLog("REST connection auth=valid status=200 derp_regions=2")
                return
            }

            if request.path.hasSuffix("/coordinate") {
                guard auth == "valid" else {
                    try sendJSON(client, status: 401, body: #"{"message":"invalid api key"}"#)
                    appendLog("COORDINATE auth=\(auth) status=401")
                    return
                }
                guard request.query == "version=2.0",
                      request.headers["upgrade"]?.lowercased() == "websocket",
                      request.headers["connection"]?.lowercased().contains("upgrade") == true,
                      request.headers["sec-websocket-version"] == "13",
                      request.headers["sec-websocket-key"] == webSocketKey else {
                    try sendJSON(client, status: 400, body: #"{"message":"invalid websocket upgrade"}"#)
                    appendLog("COORDINATE auth=valid status=400 malformed_upgrade=true")
                    return
                }
                let response = [
                    "HTTP/1.1 101 Switching Protocols",
                    "Upgrade: websocket",
                    "Connection: Upgrade",
                    "Sec-WebSocket-Accept: \(webSocketAccept)",
                    "",
                    "",
                ].joined(separator: "\r\n")
                try sendAll(client, Data(response.utf8))
                var frame = Data([0x82, UInt8(coordinatePayload.count)])
                frame.append(coordinatePayload)
                try sendAll(client, frame)
                let subprotocol = request.headers["sec-websocket-protocol"] == nil ? "absent" : "present"
                let extensions = request.headers["sec-websocket-extensions"] == nil ? "absent" : "present"
                appendLog("COORDINATE auth=valid status=101 version=2.0 token_header=present subprotocol=\(subprotocol) extensions=\(extensions) binary_bytes=\(coordinatePayload.count)")
                return
            }

            try sendJSON(client, status: 404, body: #"{"message":"not found"}"#)
            appendLog("UNKNOWN status=404")
        } catch {
            return
        }
    }

    private func readRequest(_ client: Int32) throws -> Request {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            guard data.count < 65_536 else { throw FixtureError.malformedRequest }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(client, buffer.baseAddress, buffer.count, 0)
            }
            guard count > 0 else { throw FixtureError.malformedRequest }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FixtureError.malformedRequest }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { throw FixtureError.malformedRequest }
        let target = String(requestLine[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw FixtureError.malformedRequest }
            let name = line[..<separator].lowercased()
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(
            path: String(targetParts[0]),
            query: targetParts.count == 2 ? String(targetParts[1]) : nil,
            headers: headers
        )
    }

    private func sendJSON(_ client: Int32, status: Int, body: String) throws {
        let reason = status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Bad Request"
        try sendResponse(client, status: "\(status) \(reason)", contentType: "application/json", body: Data(body.utf8))
    }

    private func sendResponse(_ client: Int32, status: String, contentType: String, body: Data) throws {
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        try sendAll(client, Data(head.utf8) + body)
    }

    private func sendAll(_ client: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.send(client, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            guard written > 0 else { throw FixtureError.socketFailure }
            offset += written
        }
    }

    private func authenticationLabel(_ token: String?) -> String {
        guard let token else { return "missing" }
        return token == validToken ? "valid" : "invalid"
    }

    private func appendLog(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            return
        }
    }
}

private struct Request {
    let path: String
    let query: String?
    let headers: [String: String]
}

private enum FixtureError: Error {
    case invalidArguments
    case socketFailure
    case malformedRequest
}
