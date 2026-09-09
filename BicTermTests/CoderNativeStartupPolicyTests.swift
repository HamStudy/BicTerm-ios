import BicTermCore
import Foundation
import XCTest
@testable import BicTerm

@MainActor
final class CoderNativeStartupPolicyTests: XCTestCase {
    func testExplicitStartAutoWaitsForBlockingScript() async throws {
        try await verifyAutoPolicy(blocks: true)
    }

    func testExplicitStartAutoDoesNotWaitForNonblockingScript() async throws {
        try await verifyAutoPolicy(blocks: false)
    }

    private func verifyAutoPolicy(blocks: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let name = blocks ? "g12-auto-blocking" : "g12-auto-nonblocking"
        let base = root.appendingPathComponent("Fixtures/run/coder-acceptance/\(name)")
        struct Snapshot: Decodable { let workspace_id: UUID }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: base.appendingPathComponent("before-stop.json")))
        let env = try String(contentsOf: root.appendingPathComponent("Fixtures/run/coder-dev.env"), encoding: .utf8)
        let values = Dictionary(uniqueKeysWithValues: env.split(separator: "\n").compactMap { line -> (String, String)? in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        })
        let token = try XCTUnwrap(values["CODER_SESSION_TOKEN"])
        let server = try CoderServer(name: "native-auto", baseURL: XCTUnwrap(values["CODER_URL"].flatMap(URL.init(string:))), tokenKeychainTag: "native-auto")
        let starter = CoderWorkspaceStarter(loader: SystemCoderRequestLoader())
        let before = try await starter.fetchWorkspace(server: server, token: token, workspaceID: snapshot.workspace_id)
        XCTAssertEqual(before.latestBuild.status, "stopped")

        let operation = Task { await starter.start(server: server, token: token, workspaceID: snapshot.workspace_id, agentID: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let entered = FileManager.default.fileExists(atPath: base.appendingPathComponent("startup-entered").path)
            var waiting = false
            if case .waitingForAgent(let state) = starter.phase { waiting = state.contains("starting") }
            if entered && (blocks ? waiting : starter.phase == .ready) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("startup-entered").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("startup-completed").path))
        if blocks {
            XCTAssertNotEqual(starter.phase, .ready)
        } else {
            XCTAssertEqual(starter.phase, .ready, "Auto must permit login while the nonblocking script is held")
        }
        try Data("release".utf8).write(to: base.appendingPathComponent("release-startup"), options: .atomic)
        let failure = await operation.value
        XCTAssertNil(failure)
        XCTAssertEqual(starter.startPostCount, 1)
        print("AUTO_POLICY blocks=\(blocks) observed with real held script")
    }
}
