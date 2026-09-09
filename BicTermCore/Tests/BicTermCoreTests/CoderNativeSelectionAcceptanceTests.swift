import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeSelectionAcceptanceTests: XCTestCase {
    func testNativeMultipleAgentsRequireAnExplicitSelection() async throws {
        let fixture = try await CoderNativeFixture.load(name: "g12-selection")
        XCTAssertEqual(Set(fixture.workspace.agents.map(\.name)), ["main", "sidecar"])
        XCTAssertTrue(fixture.workspace.agents.allSatisfy(\.isConnected))

        do {
            _ = try await fixture.resolver.resolve(CoderReference(serverID: fixture.server.id, workspaceID: fixture.workspace.id))
            XCTFail("An ambiguous live workspace must not select its first agent")
        } catch {
            XCTAssertEqual(error, .agentUnavailable)
        }
    }

    func testNativeExactNameAndUUIDReachTheirCurrentBuildAgent() async throws {
        let fixture = try await CoderNativeFixture.load(name: "g12-selection")
        for agent in fixture.workspace.agents {
            for option in ["coder.agentName", "coder.agentID"] {
                let options = try ProtocolOptions([
                    option: .string(option == "coder.agentName" ? agent.name : agent.id.uuidString)
                ])
                let transport = fixture.transport()
                let sink = TransportTestSink()
                let output = await transport.output
                let collector = Task {
                    for await bytes in output { await sink.append(bytes) }
                }
                do {
                    try await transport.connect(to: fixture.connection(options: options), cols: 80, rows: 24)
                    try await transport.send(Data("printf '\\nG12-AGENT:%s\\n' \"$BICTERM_ACCEPTANCE_AGENT\"\n".utf8))
                    let matched = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                        await String(decoding: sink.snapshot(), as: UTF8.self).contains("G12-AGENT:\(agent.name)")
                    }
                    XCTAssertTrue(matched, "\(option) must reach \(agent.name), not another current agent")
                } catch {
                    await transport.close()
                    collector.cancel()
                    throw error
                }
                await transport.close()
                collector.cancel()
            }
        }
    }

    func testNativeUnknownUUIDDoesNotFallBackToTheSavedName() async throws {
        let fixture = try await CoderNativeFixture.load(name: "g12-selection")
        let options = try ProtocolOptions([
            "coder.agentID": .string(UUID().uuidString),
            "coder.agentName": .string("main")
        ])
        let transport = fixture.transport()

        do {
            try await transport.connect(to: fixture.connection(options: options), cols: 80, rows: 24)
            XCTFail("An absent explicit UUID must not fall back to the saved name")
        } catch let error as TransportError {
            XCTAssertEqual(error, .reconnectRequired)
        }
        await transport.close()
    }

    func testNativeOldBuildUUIDRequiresReresolutionAfterRebuild() async throws {
        struct PreviousBuild: Decodable {
            struct Agent: Decodable { let id: UUID; let name: String }
            let agents: [Agent]
        }
        let fixture = try await CoderNativeFixture.load(name: "g12-selection")
        let path = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-acceptance/g12-selection/previous-state.json")
        let previous = try JSONDecoder().decode(PreviousBuild.self, from: Data(contentsOf: path))
        let old = try XCTUnwrap(previous.agents.first { $0.name == "main" })
        XCTAssertFalse(fixture.workspace.agents.contains { $0.id == old.id })
        let options = try ProtocolOptions(["coder.agentID": .string(old.id.uuidString)])
        let transport = fixture.transport()

        do {
            try await transport.connect(to: fixture.connection(options: options), cols: 80, rows: 24)
            XCTFail("An old build's UUID must not acquire a replacement agent")
        } catch let error as TransportError {
            XCTAssertEqual(error, .reconnectRequired)
        }
        await transport.close()
    }
}
