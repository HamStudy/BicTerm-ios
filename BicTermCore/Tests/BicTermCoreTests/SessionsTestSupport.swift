import Foundation
import XCTest
@testable import BicTermCore

actor InMemorySnapshotStore: SessionSnapshotStoreProtocol {
    private var snapshots: [String: SessionSnapshot] = [:]

    func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot] {
        Array(snapshots.values)
    }

    func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot? {
        snapshots[sceneID]
    }

    func save(_ snapshot: SessionSnapshot) async throws(PersistenceError) {
        snapshots[snapshot.sceneID] = snapshot
    }

    func deleteSnapshot(sceneID: String) async throws(PersistenceError) {
        snapshots[sceneID] = nil
    }
}

/// Scripted in-memory ``SessionTransport``. `close()` finishes the output
/// stream (mirroring SSHTransport's teardown); `finishOutput()` simulates
/// a remote drop WITHOUT a close call.
actor FakeSessionTransport: SessionTransport {
    enum ConnectBehavior: Sendable {
        case succeed
        case fail(SessionTransportError)
        case gated
    }

    private let behavior: ConnectBehavior
    private let continuation: AsyncStream<Data>.Continuation
    nonisolated let outputStream: AsyncStream<Data>

    private(set) var connectCalls = 0
    private(set) var closeCalls = 0
    private(set) var sent: [Data] = []
    private(set) var resizes: [(cols: Int, rows: Int)] = []
    private(set) var lastConnection: Connection?
    private(set) var lastSize: (cols: Int, rows: Int)?

    private var gateReleased = false
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []

    init(behavior: ConnectBehavior = .succeed) {
        self.behavior = behavior
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.outputStream = stream
        self.continuation = continuation
    }

    var output: AsyncStream<Data> { outputStream }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(SessionTransportError) {
        connectCalls += 1
        lastConnection = connection
        lastSize = (cols: cols, rows: rows)
        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .gated:
            if !gateReleased {
                await withCheckedContinuation { connectWaiters.append($0) }
            }
        }
    }

    func send(_ bytes: Data) async throws(SessionTransportError) {
        sent.append(bytes)
    }

    func resize(cols: Int, rows: Int) async {
        resizes.append((cols: cols, rows: rows))
    }

    func close() async {
        closeCalls += 1
        continuation.finish()
    }

    func releaseConnectGate() {
        gateReleased = true
        let waiters = connectWaiters
        connectWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func yield(_ bytes: Data) {
        continuation.yield(bytes)
    }

    func finishOutput() {
        continuation.finish()
    }
}

final class FakeSessionTransportFactory: SessionTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedBehaviors: [FakeSessionTransport.ConnectBehavior]
    private let fallbackBehavior: FakeSessionTransport.ConnectBehavior
    private var created: [FakeSessionTransport] = []

    init(
        queued: [FakeSessionTransport.ConnectBehavior] = [],
        fallback: FakeSessionTransport.ConnectBehavior = .succeed
    ) {
        self.queuedBehaviors = queued
        self.fallbackBehavior = fallback
    }

    var transports: [FakeSessionTransport] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return created.count
    }

    func makeTransport() -> any SessionTransport {
        lock.lock()
        defer { lock.unlock() }
        let behavior = queuedBehaviors.isEmpty ? fallbackBehavior : queuedBehaviors.removeFirst()
        let transport = FakeSessionTransport(behavior: behavior)
        created.append(transport)
        return transport
    }
}

func waitForState(
    _ registry: SessionRegistry,
    sceneID: String,
    timeoutMilliseconds: UInt64 = 5000,
    matching predicate: @Sendable (SessionState) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(timeoutMilliseconds)
    while clock.now < deadline {
        if let state = await registry.state(sceneID: sceneID), predicate(state) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func makeUnitConnection(name: String = "unit", id: UUID = UUID()) throws -> Connection {
    try Connection(
        id: id,
        name: name,
        type: .ssh,
        host: "unit.invalid",
        port: 22,
        username: "unit",
        keyReference: "unit-key"
    )
}
