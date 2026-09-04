import Foundation
import XCTest
@testable import BicTermCore

/// Runs the SAME ``TransportConformanceSuite`` as FakeTransport against the
/// live hop1 fixture (127.0.0.1:12222), proving the abstraction fits a real
/// protocol. Test method names are identical to
/// `FakeTransportConformanceTests` — one suite, two conformers.
///
/// Fixture hygiene: every live connection authenticates with the valid
/// fixture key (no PerSourcePenalties); the failure-path test dials the
/// closed port 9 (TCP refused, no sshd contact); quiesce uses the
/// deterministic zsh pattern with a 15s window for loaded hosts.
final class SSHTransportConformanceTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        try await super.tearDown()
    }

    private let quiesceCommand =
        "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"

    private func makeSuite() async throws -> TransportConformanceSuite {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier()
        let sink = TransportTestSink()
        return TransportConformanceSuite(
            expectedResumeStrategy: .rehandshake,
            expectedConnectFailure: .unreachable,
            makeTransport: {
                SSHTransport(
                    hostKeyVerifier: verifier,
                    authenticationKeyProvider: StaticKeyProvider(key: key)
                )
            },
            connectWorking: { transport in
                try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
                let stream = await transport.output
                self.collectors.append(Task {
                    for await chunk in stream { await sink.append(chunk) }
                    await sink.markFinished()
                })
                try await transport.send(Data(self.quiesceCommand.utf8))
                let ready = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains("__READY__")
                }
                XCTAssertTrue(ready, "shell did not reach ready marker")
                await sink.reset()
            },
            roundTrip: { transport, marker in
                try await transport.send(Data("printf '\(marker)\\n'\n".utf8))
                return await waitForSuiteCondition(timeoutMilliseconds: 8000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains(marker)
                }
            },
            verifyResize: { transport, cols, rows in
                await sink.reset()
                try await transport.send(Data("stty size\n".utf8))
                return await waitForSuiteCondition(timeoutMilliseconds: 8000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains("\(rows) \(cols)")
                }
            },
            outputFinished: { await sink.isFinished },
            makeFailingTransport: {
                SSHTransport(
                    hostKeyVerifier: verifier,
                    authenticationKeyProvider: StaticKeyProvider(key: key)
                )
            },
            connectFailing: { transport in
                let connection = try Connection(
                    name: "closed-port",
                    type: .ssh,
                    host: "127.0.0.1",
                    port: 9,
                    username: SSHTestFixture.username,
                    keyReference: "fixture-ed25519"
                )
                try await transport.connect(to: connection, cols: 80, rows: 24)
            }
        )
    }

    func testConnectSucceedsAndOutputStreamIsLive() async throws {
        try await makeSuite().runConnectSucceedsAndOutputStreamIsLive()
    }

    func testInputOutputRoundTrip() async throws {
        try await makeSuite().runInputOutputRoundTrip()
    }

    func testResizeIsObserved() async throws {
        try await makeSuite().runResizeIsObserved()
    }

    func testSuspendResumeFollowsDeclaredStrategy() async throws {
        try await makeSuite().runSuspendResumeFollowsDeclaredStrategy()
    }

    func testCloseIsTerminalIdempotentAndFinishesOutput() async throws {
        try await makeSuite().runCloseIsTerminalIdempotentAndFinishesOutput()
    }

    func testSendBeforeConnectThrowsTypedChannelDenied() async throws {
        try await makeSuite().runSendBeforeConnectThrowsTypedChannelDenied()
    }

    func testConnectFailureSurfacesTypedTransportError() async throws {
        try await makeSuite().runConnectFailureSurfacesTypedTransportError()
    }
}
