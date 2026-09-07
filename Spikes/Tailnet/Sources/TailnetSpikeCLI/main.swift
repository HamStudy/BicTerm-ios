import Foundation
import TailnetSpike

@main
struct TailnetSpikeCommand {
    private static let agentID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private static let expectedBinaryPayload = Data("fixture-coordinate-binary".utf8)

    static func main() {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            let endpoints = try TailnetEndpoints(
                baseURL: arguments.baseURL,
                agentID: agentID,
                allowsInsecureLoopback: true
            )
            let connectionRequest = try endpoints.connectionRequest(token: arguments.token)
            let connectionInfo = try LoopbackAgentConnectionClient().fetch(connectionRequest)
            guard connectionInfo.derpMap.regions.count == 2,
                  connectionInfo.derpForceWebSockets,
                  connectionInfo.disableDirectConnections,
                  connectionInfo.hostnameSuffix == ".coder.fixture" else {
                throw CommandError.unexpectedConnectionPayload
            }
            print("PASS REST decoded AgentConnectionInfo: regions=2 force_websockets=true direct_disabled=true hostname_suffix=.coder.fixture")

            let probe = CoordinateWebSocketProbe()
            let valid = try probe.connect(endpoints.coordinateRequest(token: arguments.token))
            guard valid == .upgraded(binaryPayload: expectedBinaryPayload) else {
                throw CommandError.validTokenDidNotUpgrade
            }
            print("PASS coordinate valid auth: HTTP 101, binary frame bytes=\(expectedBinaryPayload.count)")

            let missing = try probe.connect(endpoints.coordinateRequest(token: nil))
            guard missing == .rejected(statusCode: 401) else {
                throw CommandError.missingTokenWasNotRejected
            }
            print("PASS coordinate missing auth: HTTP 401")

            let invalid = try probe.connect(endpoints.coordinateRequest(token: "invalid-fixture-token"))
            guard invalid == .rejected(statusCode: 401) else {
                throw CommandError.invalidTokenWasNotRejected
            }
            print("PASS coordinate invalid auth: HTTP 401")
            print("ENTRYPOINT VERDICT: PASS — REST decode and authenticated WebSocket upgrade only")
            print("SCOPE LIMIT: binary WebSocket stream -> yamux -> dRPC -> protobuf remains unimplemented")
        } catch {
            FileHandle.standardError.write(Data("tailnet-spike FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
}

private struct Arguments {
    let baseURL: URL
    let token: String

    static func parse(_ arguments: [String]) throws -> Arguments {
        var baseURL: URL?
        var token: String?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw CommandError.invalidArguments }
            switch arguments[index] {
            case "--base-url": baseURL = URL(string: arguments[index + 1])
            case "--token": token = arguments[index + 1]
            default: throw CommandError.invalidArguments
            }
            index += 2
        }
        guard let baseURL, let token, !token.isEmpty else { throw CommandError.invalidArguments }
        return Arguments(baseURL: baseURL, token: token)
    }
}

private enum CommandError: Error {
    case invalidArguments
    case unexpectedConnectionPayload
    case validTokenDidNotUpgrade
    case missingTokenWasNotRejected
    case invalidTokenWasNotRejected
}
