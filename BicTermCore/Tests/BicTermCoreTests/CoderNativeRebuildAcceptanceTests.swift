import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeRebuildAcceptanceTests: XCTestCase {
    func testLiveRebuildEndsOldStreamAndFreshConnectionResolvesReplacement() async throws {
        let fixture = try await CoderNativeFixture.load(name: "g12-rebuild")
        let oldAgent = try XCTUnwrap(fixture.workspace.agents.first)
        let transport = fixture.transport()
        let observation = RebuildStreamObservation()
        let output = await transport.output
        let collector = Task {
            for await bytes in output { await observation.append(bytes) }
            await observation.finish()
        }
        do {
            try await transport.connect(to: fixture.connection(), cols: 80, rows: 24)
            try await transport.send(Data("printf '\\nG12-BEFORE:%s\\n' \"$BICTERM_ACCEPTANCE_SPACE\"\n".utf8))
            let live = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                await observation.contains("G12-BEFORE:g12-rebuild")
            }
            XCTAssertTrue(live)
            let base = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-acceptance/g12-rebuild")
            try Data().write(to: base.appendingPathComponent("rebuild-request"), options: .atomic)
            let ended = await waitForSuiteCondition(timeoutMilliseconds: 60000) { await observation.finished }
            XCTAssertTrue(ended, "A real agent replacement must finish the existing output stream")
            let rebuilt = await waitForSuiteCondition(timeoutMilliseconds: 60000) {
                FileManager.default.fileExists(atPath: base.appendingPathComponent("rebuild-ready").path)
            }
            XCTAssertTrue(rebuilt)
            await transport.close()

            let reference = CoderReference(serverID: fixture.server.id, workspaceID: fixture.workspace.id)
            let endpoint = try await fixture.resolver.resolve(reference)
            XCTAssertNotEqual(endpoint.agentID, oldAgent.id)
            do {
                _ = try await fixture.resolver.resolve(reference, selecting: .id(oldAgent.id))
                XCTFail("The replaced UUID must not resolve to the new agent")
            } catch {
                XCTAssertEqual(error, .agentUnavailable)
            }
            try await verifyReplacement(fixture)
            print("NATIVE_REBUILD old stream ended; old UUID rejected; fresh agent \(endpoint.agentID) connected")
        } catch {
            await transport.close()
            collector.cancel()
            throw error
        }
        await transport.close()
        collector.cancel()
    }

    private func verifyReplacement(_ fixture: CoderNativeFixture) async throws {
        let transport = fixture.transport()
        let sink = TransportTestSink()
        let output = await transport.output
        let collector = Task { for await bytes in output { await sink.append(bytes) } }
        do {
            try await transport.connect(to: fixture.connection(), cols: 80, rows: 24)
            try await transport.send(Data("printf '\\nG12-AFTER:%s\\n' \"$BICTERM_ACCEPTANCE_SPACE\"\n".utf8))
            let received = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                await String(decoding: sink.snapshot(), as: UTF8.self).contains("G12-AFTER:g12-rebuild")
            }
            XCTAssertTrue(received, "A fresh connection must execute on the rebuilt workspace")
        } catch {
            await transport.close()
            collector.cancel()
            throw error
        }
        await transport.close()
        collector.cancel()
    }
}

private actor RebuildStreamObservation {
    private var bytes = Data()
    private(set) var finished = false
    func append(_ data: Data) { bytes.append(data) }
    func finish() { finished = true }
    func contains(_ text: String) -> Bool { String(decoding: bytes, as: UTF8.self).contains(text) }
}
