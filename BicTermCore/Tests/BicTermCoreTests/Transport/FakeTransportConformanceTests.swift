import Foundation
import XCTest
@testable import BicTermCore

/// Runs the full ``TransportConformanceSuite`` against the in-memory
/// loopback ``FakeTransport`` (roaming-resume script) — zero SSH types in
/// the exercised path. Rehandshake-strategy coverage is added by the
/// script-level tests below (and live by SSHTransportConformanceTests).
final class FakeTransportConformanceTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        try await super.tearDown()
    }

    private func makeSuite(script: FakeTransport.Script = FakeTransport.Script()) -> TransportConformanceSuite {
        let sink = TransportTestSink()
        return TransportConformanceSuite(
            expectedResumeStrategy: script.resumeStrategy,
            expectedConnectFailure: .unreachable,
            makeTransport: {
                FakeTransport(script: script)
            },
            connectWorking: { transport in
                try await transport.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)
                let stream = await transport.output
                self.collectors.append(Task {
                    for await chunk in stream { await sink.append(chunk) }
                    await sink.markFinished()
                })
            },
            roundTrip: { transport, marker in
                try await transport.send(Data(marker.utf8))
                return await waitForSuiteCondition {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains(marker)
                }
            },
            verifyResize: { transport, cols, rows in
                guard let fake = transport as? FakeTransport else { return false }
                let resizes = await fake.resizes
                return resizes.contains { $0.cols == cols && $0.rows == rows }
            },
            outputFinished: { await sink.isFinished },
            makeFailingTransport: {
                var failing = script
                failing.connectError = .unreachable
                return FakeTransport(script: failing)
            },
            connectFailing: { transport in
                try await transport.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)
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

    func testRehandshakeScriptSuspendsByClosingAndRejectsResume() async throws {
        let script = FakeTransport.Script(resumeStrategy: .rehandshake)
        let transport = FakeTransport(script: script)
        try await transport.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)

        await transport.suspend()

        let phase = await transport.phase
        XCTAssertEqual(phase, .closed, "rehandshake suspend must tear the connection down")
        await assertThrowsTransportError(.resumeUnsupported) {
            try await transport.resume()
        }
    }

    func testScriptedConnectLatencyAndFailureInjection() async throws {
        let failing = FakeTransport(script: FakeTransport.Script(connectError: .authenticationFailed))
        await assertThrowsTransportError(.authenticationFailed) {
            try await failing.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)
        }

        let slow = FakeTransport(script: FakeTransport.Script(connectLatency: .milliseconds(150)))
        try await slow.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)
        let phase = await slow.phase
        XCTAssertEqual(phase, .connected)
        await slow.close()
    }

    func testRoamingResumeFailureSurfacesTypedError() async throws {
        let transport = FakeTransport(script: FakeTransport.Script(resumeError: .unreachable))
        try await transport.connect(to: makeUnitConnection(name: "fake"), cols: 80, rows: 24)
        await transport.suspend()
        await assertThrowsTransportError(.unreachable) {
            try await transport.resume()
        }
        await transport.close()
    }
}
