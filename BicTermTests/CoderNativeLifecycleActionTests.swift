import BicTermCore
import Foundation
import XCTest
@testable import BicTerm

@MainActor
final class CoderNativeLifecycleActionTests: XCTestCase {
    func testDormantWorkspaceRequiresReactivationWithoutMutation() async throws {
        try await verifyAction(variant: "dormant", title: "Workspace is dormant")
    }

    func testParameterMismatchRequiresAnswersWithoutMutation() async throws {
        try await verifyAction(variant: "parameters", title: "Startup parameters required")
    }

    private func verifyAction(variant: String, title: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let env = try String(contentsOf: root.appendingPathComponent("Fixtures/run/coder-dev.env"), encoding: .utf8)
        let values = Dictionary(uniqueKeysWithValues: env.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
        let token = try XCTUnwrap(values["CODER_SESSION_TOKEN"])
        let server = try CoderServer(name: "native-actions", baseURL: XCTUnwrap(values["CODER_URL"].flatMap(URL.init(string:))), tokenKeychainTag: "native-actions")
        let snapshots = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/run/coder-acceptance/action-workspaces.json")))
        let workspaceID = try XCTUnwrap(snapshots[variant])
        let ledger = NativeActionRequestLedger()
        let starter = CoderWorkspaceStarter(loader: ledger)
        let before = try await starter.fetchWorkspace(server: server, token: token, workspaceID: workspaceID)
        XCTAssertEqual(before.latestBuild.status, "stopped")
        XCTAssertEqual(before.isDormant, variant == "dormant")

        let operation = Task { await starter.start(server: server, token: token, workspaceID: workspaceID, agentID: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            switch starter.phase {
            case .failed, .waitingForAgent, .waitingForBuild, .ready:
                break
            default:
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }
        if case .failed = starter.phase {} else { operation.cancel() }
        let failure = await operation.value

        XCTAssertEqual(failure?.title, title)
        XCTAssertEqual(starter.startPostCount, 0)
        let after = try await starter.fetchWorkspace(server: server, token: token, workspaceID: workspaceID)
        XCTAssertEqual(after, before, "An action-required attempt must not change lifecycle state")
        let methods = await ledger.methods
        XCTAssertTrue(methods.allSatisfy { $0 == "GET" }, "Lifecycle and parameter gates must issue reads only")
        print("NATIVE_ACTION \(variant) methods=\(methods.joined(separator: ",")) title=\(failure?.title ?? "none") unchanged=\(after == before)")
    }
}

private actor NativeActionRequestLedger: CoderRequestLoading {
    private let upstream = SystemCoderRequestLoader()
    private(set) var methods: [String] = []

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        methods.append(request.httpMethod ?? "GET")
        return try await upstream.load(request)
    }
}
