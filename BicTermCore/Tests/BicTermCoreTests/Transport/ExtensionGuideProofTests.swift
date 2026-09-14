import Foundation
import XCTest
@testable import BicTermCore

private extension ProtocolDescriptor {
    static let uppercaseEcho = ProtocolDescriptor(
        id: ConnectionType.uppercaseEcho.rawValue,
        displayName: "Uppercase Echo",
        supportsAgentForwarding: false,
        supportsJumpChain: false,
        supportsRoamingResume: true,
        requiresServerComponent: false,
        defaultPort: 7,
        keyAlgorithmsAccepted: [],
        resumeStrategy: .nativeRoaming
    )
}

private actor UppercaseEchoTransport: TerminalTransport {
    private enum Phase {
        case idle
        case connected
        case suspended
        case closed
    }

    nonisolated let script: TransportConformanceScript
    nonisolated var resumeStrategy: ResumeStrategy { script.resumeStrategy }

    private let continuation: AsyncStream<Data>.Continuation
    nonisolated let outputStream: AsyncStream<Data>
    var output: AsyncStream<Data> { outputStream }

    private var phase = Phase.idle
    private(set) var connectAttempts = 0
    private(set) var authenticationAttempts = 0
    private(set) var resumeAttempts = 0
    private(set) var resizes: [(cols: Int, rows: Int)] = []

    init(script: TransportConformanceScript = TransportConformanceScript()) {
        self.script = script
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.outputStream = stream
        self.continuation = continuation
    }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        connectAttempts += 1
        guard connection.type == .uppercaseEcho, phase == .idle else {
            throw .channelDenied
        }
        if script.connectLatency > .zero {
            try? await Task.sleep(for: script.connectLatency)
        }
        if let error = script.connectError { throw error }
        authenticationAttempts += 1
        phase = .connected
        if let greeting = script.greeting {
            continuation.yield(greeting)
        }
    }

    func send(_ bytes: Data) async throws(TransportError) {
        guard phase == .connected else { throw .channelDenied }
        guard script.echoesInput else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        continuation.yield(Data(text.uppercased().utf8))
    }

    func resize(cols: Int, rows: Int) async {
        guard phase == .connected, cols > 0, rows > 0 else { return }
        resizes.append((cols: cols, rows: rows))
    }

    func suspend() async {
        switch resumeStrategy {
        case .nativeRoaming:
            if phase == .connected { phase = .suspended }
        case .rehandshake:
            await close()
        }
    }

    func resume() async throws(TransportError) {
        resumeAttempts += 1
        guard resumeStrategy == .nativeRoaming else { throw .resumeUnsupported }
        if let error = script.resumeError { throw error }
        guard phase == .suspended else { throw .channelDenied }
        phase = .connected
    }

    func close() async {
        guard phase != .closed else { return }
        phase = .closed
        continuation.finish()
    }

    func roamingResumeObservation() -> RoamingResumeObservation {
        RoamingResumeObservation(
            connectAttempts: connectAttempts,
            authenticationAttempts: authenticationAttempts,
            resumeAttempts: resumeAttempts
        )
    }
}

private struct UppercaseEchoTransportFactory: TerminalTransportFactory {
    let script: TransportConformanceScript

    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        guard connection.type == .uppercaseEcho else {
            throw .protocolUnavailable(protocolID: connection.type.rawValue)
        }
        return UppercaseEchoTransport(script: script)
    }
}

/// Mechanical proof for Docs/ADDING-A-PROTOCOL.md: this third conformer was
/// built from the guide's contract, descriptor, factory, registry, model, and
/// conformance-hook steps, without using SSH implementation details.
final class ExtensionGuideProofTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        try await super.tearDown()
    }

    private func makeConnection(name: String = "uppercase-echo") throws -> Connection {
        try Connection(
            name: name,
            type: .uppercaseEcho,
            host: "loopback.invalid",
            port: ProtocolDescriptor.uppercaseEcho.defaultPort,
            username: "proof",
            customKeys: ["none"]
        )
    }

    private func makeRegisteredTransport(
        script: TransportConformanceScript = TransportConformanceScript(),
        connection: Connection
    ) throws -> any TerminalTransport {
        var registry = TransportRegistry()
        registry.register(
            .uppercaseEcho,
            factory: UppercaseEchoTransportFactory(script: script)
        )
        return try registry.makeTransport(for: connection)
    }

    private func makeSuite() throws -> TransportConformanceSuite {
        let sink = TransportTestSink()
        let workingConnection = try makeConnection()
        return TransportConformanceSuite(
            descriptor: .uppercaseEcho,
            expectedResumeStrategy: .nativeRoaming,
            expectedConnectFailure: .unreachable,
            makeTransport: {
                try self.makeRegisteredTransport(connection: workingConnection)
            },
            connectWorking: { transport in
                try await transport.connect(to: workingConnection, cols: 80, rows: 24)
                let stream = await transport.output
                self.collectors.append(Task {
                    for await chunk in stream { await sink.append(chunk) }
                    await sink.markFinished()
                })
            },
            roundTrip: { transport, marker in
                let lowercaseMarker = marker.lowercased()
                try await transport.send(Data(lowercaseMarker.utf8))
                return await waitForSuiteCondition {
                    await String(decoding: sink.snapshot(), as: UTF8.self)
                        .contains(lowercaseMarker.uppercased())
                }
            },
            verifyResize: { transport, cols, rows in
                guard let echo = transport as? UppercaseEchoTransport else { return false }
                let resizes = await echo.resizes
                return resizes.contains { $0.cols == cols && $0.rows == rows }
            },
            outputFinished: { await sink.isFinished },
            makeFailingTransport: {
                var script = TransportConformanceScript()
                script.connectError = .unreachable
                return try self.makeRegisteredTransport(script: script, connection: workingConnection)
            },
            connectFailing: { transport in
                try await transport.connect(to: workingConnection, cols: 80, rows: 24)
            },
            expectedResumeFailure: .unreachable,
            makeResumeFailingTransport: {
                var script = TransportConformanceScript()
                script.resumeError = .unreachable
                return try self.makeRegisteredTransport(script: script, connection: workingConnection)
            },
            observeRoamingResume: { transport in
                guard let echo = transport as? UppercaseEchoTransport else {
                    return RoamingResumeObservation(
                        connectAttempts: -1,
                        authenticationAttempts: -1,
                        resumeAttempts: -1
                    )
                }
                return await echo.roamingResumeObservation()
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

    func testResumeFailureSurfacesTypedTransportError() async throws {
        try await makeSuite().runResumeFailureSurfacesTypedTransportError()
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

    func testDescriptorRegistrationResolvesPersistedConnection() async throws {
        let original = try makeConnection(name: "persisted-uppercase-echo")
        let encoded = try JSONEncoder().encode(original)
        let persisted = try JSONDecoder().decode(Connection.self, from: encoded)
        var registry = TransportRegistry()
        registry.register(
            .uppercaseEcho,
            factory: UppercaseEchoTransportFactory(script: TransportConformanceScript())
        )

        XCTAssertEqual(
            registry.descriptor(forProtocolID: persisted.type.rawValue),
            .uppercaseEcho
        )
        let transport = try registry.makeTransport(for: persisted)
        XCTAssertTrue(transport is UppercaseEchoTransport)
        await transport.close()
    }
}
