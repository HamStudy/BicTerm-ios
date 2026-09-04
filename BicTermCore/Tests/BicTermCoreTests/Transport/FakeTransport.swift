import Foundation
@testable import BicTermCore

/// In-memory loopback ``TerminalTransport`` conformer (test-only). All
/// behavior is scripted: connect latency, failure injection, and BOTH
/// resume strategies (`.nativeRoaming` reattaches the same instance
/// without re-auth; `.rehandshake` closes on suspend and rejects resume).
/// Runs the full ``TransportConformanceSuite`` as the protocol-agnostic
/// proof of the abstraction.
actor FakeTransport: TerminalTransport {
    struct Script: Sendable {
        var resumeStrategy: ResumeStrategy = .nativeRoaming
        var connectLatency: Duration = .zero
        var connectError: TransportError?
        var resumeError: TransportError?
        var echoesInput = true
        var greeting: Data?

        init(
            resumeStrategy: ResumeStrategy = .nativeRoaming,
            connectLatency: Duration = .zero,
            connectError: TransportError? = nil,
            resumeError: TransportError? = nil,
            echoesInput: Bool = true,
            greeting: Data? = nil
        ) {
            self.resumeStrategy = resumeStrategy
            self.connectLatency = connectLatency
            self.connectError = connectError
            self.resumeError = resumeError
            self.echoesInput = echoesInput
            self.greeting = greeting
        }
    }

    enum Phase: Sendable {
        case idle, connected, suspended, closed
    }

    nonisolated let script: Script
    nonisolated var resumeStrategy: ResumeStrategy { script.resumeStrategy }

    private let continuation: AsyncStream<Data>.Continuation
    nonisolated let outputStream: AsyncStream<Data>
    var output: AsyncStream<Data> { outputStream }

    private(set) var phase: Phase = .idle
    private(set) var connectCalls = 0
    private(set) var resumeCalls = 0
    private(set) var sentBytes: [Data] = []
    private(set) var resizes: [(cols: Int, rows: Int)] = []
    private(set) var lastConnection: Connection?

    init(script: Script = Script()) {
        self.script = script
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.outputStream = stream
        self.continuation = continuation
    }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        connectCalls += 1
        lastConnection = connection
        if script.connectLatency > .zero {
            try? await Task.sleep(for: script.connectLatency)
        }
        if let error = script.connectError { throw error }
        guard phase == .idle else { throw .channelDenied }
        phase = .connected
        if let greeting = script.greeting {
            continuation.yield(greeting)
        }
    }

    func send(_ bytes: Data) async throws(TransportError) {
        guard phase == .connected else { throw .channelDenied }
        sentBytes.append(bytes)
        if script.echoesInput {
            continuation.yield(bytes)
        }
    }

    func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0, phase == .connected else { return }
        resizes.append((cols: cols, rows: rows))
    }

    func suspend() async {
        switch script.resumeStrategy {
        case .nativeRoaming:
            if phase == .connected { phase = .suspended }
        case .rehandshake:
            await close()
        }
    }

    func resume() async throws(TransportError) {
        resumeCalls += 1
        guard script.resumeStrategy == .nativeRoaming else { throw .resumeUnsupported }
        if let error = script.resumeError { throw error }
        guard phase == .suspended else { throw .channelDenied }
        phase = .connected
    }

    func close() async {
        guard phase != .closed else { return }
        phase = .closed
        continuation.finish()
    }

    func pushFromServer(_ bytes: Data) {
        continuation.yield(bytes)
    }
}
