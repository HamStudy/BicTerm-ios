import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeProfileIsolationTests: XCTestCase {
    func testConcurrentDistinctUsersKeepTheirStreamsAndCloseIndependent() async throws {
        struct Profile: Decodable { let name: String; let token: String; let user_id: UUID; let agent_id: UUID }
        let path = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-acceptance/profiles.json")
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: path))
        XCTAssertEqual(profiles.count, 2)
        let first = try XCTUnwrap(profiles.first)
        let second = try XCTUnwrap(profiles.last)
        XCTAssertNotEqual(first.user_id, second.user_id)
        XCTAssertNotEqual(first.agent_id, second.agent_id)
        let a = try await CoderNativeFixture.load(name: first.name, tokenOverride: first.token)
        let b = try await CoderNativeFixture.load(name: second.name, tokenOverride: second.token)
        let transportA = a.transport()
        let transportB = b.transport()
        let sinkA = TransportTestSink()
        let sinkB = TransportTestSink()
        let outputA = await transportA.output
        let outputB = await transportB.output
        let collectA = Task { for await bytes in outputA { await sinkA.append(bytes) } }
        let collectB = Task { for await bytes in outputB { await sinkB.append(bytes) } }
        do {
            async let connectA: Void = transportA.connect(to: a.connection(), cols: 80, rows: 24)
            async let connectB: Void = transportB.connect(to: b.connection(), cols: 80, rows: 24)
            _ = try await (connectA, connectB)
            let command = Data("printf '\\nG12-PROFILE:%s\\n' \"$BICTERM_ACCEPTANCE_SPACE\"\n".utf8)
            try await transportA.send(command)
            try await transportB.send(command)
            let received = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                let textA = await String(decoding: sinkA.snapshot(), as: UTF8.self)
                let textB = await String(decoding: sinkB.snapshot(), as: UTF8.self)
                return textA.contains("G12-PROFILE:\(first.name)") && textB.contains("G12-PROFILE:\(second.name)")
            }
            XCTAssertTrue(received, "Each concurrent profile must reach its own authorized workspace")
            let textA = await String(decoding: sinkA.snapshot(), as: UTF8.self)
            let textB = await String(decoding: sinkB.snapshot(), as: UTF8.self)
            XCTAssertFalse(textA.contains("G12-PROFILE:\(second.name)"))
            XCTAssertFalse(textB.contains("G12-PROFILE:\(first.name)"))
            await transportA.close()
            try await transportB.send(Data("printf '\\nG12-SURVIVOR:%s\\n' \"$BICTERM_ACCEPTANCE_SPACE\"\n".utf8))
            let survived = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                await String(decoding: sinkB.snapshot(), as: UTF8.self).contains("G12-SURVIVOR:\(second.name)")
            }
            XCTAssertTrue(survived, "Closing one native handle must not close another profile's stream")
            print("NATIVE_PROFILE_ISOLATION concurrent distinct users; own outputs only; second stream survives first close")
        } catch {
            await transportA.close()
            await transportB.close()
            collectA.cancel()
            collectB.cancel()
            throw error
        }
        await transportA.close()
        await transportB.close()
        collectA.cancel()
        collectB.cancel()
    }
}
