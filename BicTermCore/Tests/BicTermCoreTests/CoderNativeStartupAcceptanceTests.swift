import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeStartupAcceptanceTests: XCTestCase {
    func testBlockingScriptDefersConnectionUntilReleased() async throws {
        let name = "g12-startup-blocking"
        let ledger = StartupReadLedger()
        let fixture = try await CoderNativeFixture.load(name: name, loader: ledger)
        XCTAssertTrue(fixture.workspace.agents.allSatisfy(\.isConnected))
        let transport = fixture.transport()
        let completion = StartupCompletion()
        let connection = try fixture.connection()
        let task = Task {
            do {
                try await transport.connect(to: connection, cols: 80, rows: 24)
                await completion.finish()
            } catch {
                await completion.finish()
                throw error
            }
        }

        let observed = await waitForSuiteCondition(timeoutMilliseconds: 5000) {
            let reads = await ledger.reads
            let finished = await completion.finished
            return reads >= 3 || finished
        }
        XCTAssertTrue(observed)
        let prematurelyFinished = await completion.finished
        XCTAssertFalse(prematurelyFinished, "A blocking startup script must hold the connection")
        try release(name)
        try await task.value
        await transport.close()
    }

    func testNonblockingScriptPermitsConnectionBeforeRelease() async throws {
        let name = "g12-startup-nonblocking"
        let fixture = try await CoderNativeFixture.load(name: name)
        let transport = fixture.transport()

        try await transport.connect(to: fixture.connection(), cols: 80, rows: 24)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(name, "release-startup").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(name, "startup-completed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(name, "startup-entered").path))
        try release(name)
        await transport.close()
    }

    func testFailedStartupIsAnInformativeConnectionFailure() async throws {
        try await assertStartupFailure(name: "g12-startup-error", state: "start_error")
    }

    func testTimedOutStartupIsAnInformativeConnectionFailure() async throws {
        try await assertStartupFailure(name: "g12-startup-timeout", state: "start_timeout")
    }

    private func assertStartupFailure(name: String, state: String) async throws {
        let fixture = try await CoderNativeFixture.load(name: name)
        let transport = fixture.transport()

        do {
            try await transport.connect(to: fixture.connection(), cols: 80, rows: 24)
            XCTFail("Startup state \(state) must not silently connect")
        } catch let error as TransportError {
            XCTAssertTrue(error.localizedDescription.contains(state), "Startup failure must retain its state")
        }
        await transport.close()
    }

    private func path(_ name: String, _ file: String) -> URL {
        SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-acceptance/\(name)/\(file)")
    }

    private func release(_ name: String) throws {
        try Data("release".utf8).write(to: path(name, "release-startup"), options: .atomic)
    }
}

private actor StartupCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor StartupReadLedger: CoderRequestLoading {
    private let loader = SystemCoderRequestLoader()
    private(set) var reads = 0
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        let response = try await loader.load(request)
        reads += 1
        return response
    }
}
