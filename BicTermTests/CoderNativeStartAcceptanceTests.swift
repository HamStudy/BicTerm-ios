import BicTermCore
import Foundation
import XCTest
@testable import BicTerm

@MainActor
final class CoderNativeStartAcceptanceTests: XCTestCase {
    func testExplicitNativeStartPostsOnceAndFollowsNewAgentToReady() async throws {
        try await verifyNativeStart(workspace: "g12-start-explicit", loseResponse: false)
    }

    func testLostNativeStartResponseRechecksWithoutSecondPost() async throws {
        try await verifyNativeStart(workspace: "g12-start-lost", loseResponse: true)
    }

    private func verifyNativeStart(workspace name: String, loseResponse: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let env = try String(contentsOf: root.appendingPathComponent("Fixtures/run/coder-dev.env"), encoding: .utf8)
        let values = Dictionary(uniqueKeysWithValues: env.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
        struct Snapshot: Decodable {
            struct Agent: Decodable { let id: UUID }
            let workspace_id: UUID
            let agents: [Agent]
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/run/coder-acceptance/\(name)/before-stop.json")))
        let token = try XCTUnwrap(values["CODER_SESSION_TOKEN"])
        let server = try CoderServer(name: "native-start", baseURL: XCTUnwrap(values["CODER_URL"].flatMap(URL.init(string:))), tokenKeychainTag: "native-start")
        let ledger = NativeStartRequestLedger(loseResponse: loseResponse)
        let starter = CoderWorkspaceStarter(loader: ledger)
        let before = try await starter.fetchWorkspace(server: server, token: token, workspaceID: snapshot.workspace_id)
        XCTAssertEqual(before.latestBuild.status, "stopped")

        let failure = await starter.start(server: server, token: token, workspaceID: snapshot.workspace_id, agentID: nil)

        XCTAssertNil(failure)
        XCTAssertEqual(starter.phase, .ready)
        XCTAssertEqual(starter.startPostCount, 1)
        let events = await ledger.events
        let posts = events.filter { $0.method == "POST" && $0.path.hasSuffix("/builds") }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.status, 201)
        if loseResponse {
            let index = try XCTUnwrap(events.firstIndex { $0.method == "POST" })
            XCTAssertGreaterThan(events.count, index + 1)
            XCTAssertEqual(events[index + 1].method, "GET")
            XCTAssertEqual(events[index + 1].path, "/api/v2/workspaces/\(snapshot.workspace_id.uuidString.lowercased())")
        }
        let current = try await starter.fetchWorkspace(server: server, token: token, workspaceID: snapshot.workspace_id)
        let agent = try XCTUnwrap(current.latestBuild.agents.first)
        XCTAssertTrue(agent.isConnected)
        XCTAssertEqual(current.latestBuild.agentLifecycles[agent.id], "ready")
        XCTAssertFalse(snapshot.agents.contains { $0.id == agent.id })
        for event in await ledger.events { print("NATIVE_START \(name) \(event.method) \(event.path) status=\(event.status)") }
    }
}

private actor NativeStartRequestLedger: CoderRequestLoading {
    struct Event: Sendable { let method: String; let path: String; let status: Int }
    private let upstream = SystemCoderRequestLoader()
    private var loseResponse: Bool
    private(set) var events: [Event] = []
    init(loseResponse: Bool) { self.loseResponse = loseResponse }
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        let response = try await upstream.load(request)
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        events.append(Event(method: method, path: path, status: response.statusCode))
        if loseResponse, method == "POST", path.hasSuffix("/builds"), response.statusCode == 201 {
            loseResponse = false
            throw .networkFailure
        }
        return response
    }
}
