import Foundation
import XCTest
@testable import BicTermCore

/// Reusable fault/latency scenarios for in-memory conformers and fixture
/// adapters. A real transport's tests can map these controls onto its fake
/// endpoint instead of depending on ``FakeTransport`` itself.
struct TransportConformanceScript: Sendable {
    var resumeStrategy: ResumeStrategy = .nativeRoaming
    var connectLatency: Duration = .zero
    var connectError: TransportError?
    var resumeError: TransportError?
    var echoesInput = true
    var greeting: Data?
}

/// Counts captured at the protocol boundary immediately before and after a
/// native resume. The shared suite uses them to prove that resume reuses the
/// same connection/authentication rather than hiding a fresh handshake.
struct RoamingResumeObservation: Equatable, Sendable {
    let connectAttempts: Int
    let authenticationAttempts: Int
    let resumeAttempts: Int
}

/// Collects one transport's `output` stream for assertions.
actor TransportTestSink {
    private var buffer = Data()
    private(set) var isFinished = false

    func append(_ chunk: Data) { buffer.append(chunk) }
    func markFinished() { isFinished = true }
    func reset() { buffer = Data() }
    func snapshot() -> Data { buffer }
}

/// The reusable conformance suite every ``TerminalTransport`` conformer
/// runs (T11, extended by T15's guide). A conformer provides hooks for the
/// protocol-specific parts (how to connect, how to observe an echo, how to
/// observe a resize, a guaranteed-failing target); the `run*` methods hold
/// the SHARED assertions, so every conformer proves the identical
/// lifecycle: connect → I/O round-trip → resize → suspend → resume →
/// close, plus error paths and terminal-state guarantees.
///
/// Wiring pattern (one identically-named test method per conformer class):
///
/// ```swift
/// func testInputOutputRoundTrip() async throws {
///     try await makeSuite().runInputOutputRoundTrip()
/// }
/// ```
final class TransportConformanceSuite {
    /// Capability record shipped with the conformer. The suite checks that
    /// its roaming flags agree with the transport's runtime behavior.
    var descriptor: ProtocolDescriptor
    /// The strategy the conformer's descriptor must declare; suspend/resume
    /// assertions branch on it (both strategies are exercised this way).
    var expectedResumeStrategy: ResumeStrategy
    /// Error `connectFailing` must produce.
    var expectedConnectFailure: TransportError
    /// Error a scripted native resume must produce. Rehandshake conformers
    /// always prove `.resumeUnsupported` and do not use this value.
    var expectedResumeFailure: TransportError?
    /// A fresh, unconnected transport.
    var makeTransport: () async throws -> any TerminalTransport
    /// Connects to a working endpoint and leaves the conformer ready for
    /// I/O (e.g. shell quiesced), collecting output into the suite's sink.
    var connectWorking: (any TerminalTransport) async throws -> Void
    /// Sends bytes so that `marker` comes back through `output`; returns
    /// whether the marker was observed.
    var roundTrip: (any TerminalTransport, String) async throws -> Bool
    /// Returns whether a resize to (cols, rows) took effect.
    var verifyResize: (any TerminalTransport, Int, Int) async throws -> Bool
    /// Whether the connected transport's output stream has finished.
    var outputFinished: () async -> Bool
    /// A fresh transport whose `connectFailing` fails with
    /// `expectedConnectFailure`.
    var makeFailingTransport: () async throws -> any TerminalTransport
    var connectFailing: (any TerminalTransport) async throws -> Void
    /// Native-roaming failure injection. A real implementation maps this to
    /// its fixture/stub's resume-failure control.
    var makeResumeFailingTransport: (() async throws -> any TerminalTransport)?
    /// Native-roaming instrumentation. Counts must come from the conformer's
    /// connection/bootstrap boundary, not from the suite itself.
    var observeRoamingResume: ((any TerminalTransport) async -> RoamingResumeObservation)?

    init(
        descriptor: ProtocolDescriptor,
        expectedResumeStrategy: ResumeStrategy,
        expectedConnectFailure: TransportError,
        makeTransport: @escaping () async throws -> any TerminalTransport,
        connectWorking: @escaping (any TerminalTransport) async throws -> Void,
        roundTrip: @escaping (any TerminalTransport, String) async throws -> Bool,
        verifyResize: @escaping (any TerminalTransport, Int, Int) async throws -> Bool,
        outputFinished: @escaping () async -> Bool,
        makeFailingTransport: @escaping () async throws -> any TerminalTransport,
        connectFailing: @escaping (any TerminalTransport) async throws -> Void,
        expectedResumeFailure: TransportError?,
        makeResumeFailingTransport: (() async throws -> any TerminalTransport)?,
        observeRoamingResume: ((any TerminalTransport) async -> RoamingResumeObservation)?
    ) {
        self.descriptor = descriptor
        self.expectedResumeStrategy = expectedResumeStrategy
        self.expectedConnectFailure = expectedConnectFailure
        self.makeTransport = makeTransport
        self.connectWorking = connectWorking
        self.roundTrip = roundTrip
        self.verifyResize = verifyResize
        self.outputFinished = outputFinished
        self.makeFailingTransport = makeFailingTransport
        self.connectFailing = connectFailing
        self.expectedResumeFailure = expectedResumeFailure
        self.makeResumeFailingTransport = makeResumeFailingTransport
        self.observeRoamingResume = observeRoamingResume
    }

    func runConnectSucceedsAndOutputStreamIsLive() async throws {
        let transport = try await makeTransport()
        XCTAssertEqual(
            descriptor.resumeStrategy,
            expectedResumeStrategy,
            "the descriptor and conformer must declare the same resume strategy"
        )
        XCTAssertEqual(
            descriptor.supportsRoamingResume,
            expectedResumeStrategy == .nativeRoaming,
            "supportsRoamingResume must agree with resumeStrategy"
        )
        XCTAssertEqual(
            transport.resumeStrategy,
            expectedResumeStrategy,
            "the transport must honestly declare its resume strategy"
        )
        try await connectWorking(transport)
        let finished = await outputFinished()
        XCTAssertFalse(finished, "output must stay open after a successful connect")
        await transport.close()
    }

    func runInputOutputRoundTrip() async throws {
        let transport = try await makeTransport()
        try await connectWorking(transport)
        let marker = "__RT_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))__"
        let echoed = try await roundTrip(transport, marker)
        XCTAssertTrue(echoed, "sent bytes must come back through the output stream")
        await transport.close()
    }

    func runResizeIsObserved() async throws {
        let transport = try await makeTransport()
        try await connectWorking(transport)
        // Invalid dimensions are ignored, never crash (NIOSSH traps on
        // negative UInt32 conversion if a conformer forgets to validate).
        await transport.resize(cols: 0, rows: -1)
        await transport.resize(cols: 120, rows: 40)
        let observed = try await verifyResize(transport, 120, 40)
        XCTAssertTrue(observed, "resize must reach the remote side")
        await transport.close()
    }

    func runSuspendResumeFollowsDeclaredStrategy() async throws {
        let transport = try await makeTransport()
        try await connectWorking(transport)

        switch expectedResumeStrategy {
        case .nativeRoaming:
            guard let observeRoamingResume else {
                XCTFail("native-roaming conformers must expose connection/authentication counters")
                await transport.close()
                return
            }
            let beforeSuspend = await observeRoamingResume(transport)
            await transport.suspend()
            let finishedDuringSuspend = await outputFinished()
            XCTAssertFalse(
                finishedDuringSuspend,
                "roaming suspend keeps the server-side session (and stream) alive"
            )
            try await transport.resume()
            let afterResume = await observeRoamingResume(transport)
            assertNativeResumeDidNotReauthenticate(before: beforeSuspend, after: afterResume)
            let marker = "__RS_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))__"
            let echoed = try await roundTrip(transport, marker)
            XCTAssertTrue(echoed, "I/O must work after a native resume WITHOUT re-auth")
        case .rehandshake:
            await transport.suspend()
            let finished = await waitForSuiteCondition { await self.outputFinished() }
            XCTAssertTrue(finished, "rehandshake suspend closes the connection")
            await assertThrowsTransportError(.resumeUnsupported) {
                try await transport.resume()
            }
        }
        await transport.close()
    }

    func runResumeFailureSurfacesTypedTransportError() async throws {
        switch expectedResumeStrategy {
        case .nativeRoaming:
            guard
                let expectedResumeFailure,
                let makeResumeFailingTransport,
                let observeRoamingResume
            else {
                XCTFail("native-roaming conformers must provide resume-failure and observation hooks")
                return
            }
            let transport = try await makeResumeFailingTransport()
            try await connectWorking(transport)
            let beforeSuspend = await observeRoamingResume(transport)
            await transport.suspend()
            await assertThrowsTransportError(expectedResumeFailure) {
                try await transport.resume()
            }
            let afterResume = await observeRoamingResume(transport)
            assertNativeResumeDidNotReauthenticate(before: beforeSuspend, after: afterResume)
            await transport.close()
        case .rehandshake:
            let transport = try await makeTransport()
            try await connectWorking(transport)
            await transport.suspend()
            await assertThrowsTransportError(.resumeUnsupported) {
                try await transport.resume()
            }
            await transport.close()
        }
    }

    func runCloseIsTerminalIdempotentAndFinishesOutput() async throws {
        let transport = try await makeTransport()
        try await connectWorking(transport)
        await transport.close()
        let finished = await waitForSuiteCondition { await self.outputFinished() }
        XCTAssertTrue(finished, "close() must finish the output stream")
        await assertThrowsTransportError(.channelDenied) {
            try await transport.send(Data("after-close".utf8))
        }
        await transport.close()
    }

    func runSendBeforeConnectThrowsTypedChannelDenied() async throws {
        let transport = try await makeTransport()
        await assertThrowsTransportError(.channelDenied) {
            try await transport.send(Data("too-early".utf8))
        }
        await transport.close()
    }

    func runConnectFailureSurfacesTypedTransportError() async throws {
        let transport = try await makeFailingTransport()
        await assertThrowsTransportError(expectedConnectFailure) {
            try await connectFailing(transport)
        }
        await transport.close()
    }

    private func assertNativeResumeDidNotReauthenticate(
        before: RoamingResumeObservation,
        after: RoamingResumeObservation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            after.connectAttempts,
            before.connectAttempts,
            "native resume must not reconnect",
            file: file,
            line: line
        )
        XCTAssertEqual(
            after.authenticationAttempts,
            before.authenticationAttempts,
            "native resume must not re-authenticate",
            file: file,
            line: line
        )
        XCTAssertEqual(
            after.resumeAttempts,
            before.resumeAttempts + 1,
            "resume() must make exactly one native reattachment attempt",
            file: file,
            line: line
        )
    }
}

func waitForSuiteCondition(
    timeoutMilliseconds: UInt64 = 5000,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(timeoutMilliseconds)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func assertThrowsTransportError(
    _ expected: TransportError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as TransportError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
