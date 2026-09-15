import BicTermCore
import XCTest
@testable import BicTerm

@MainActor
final class ConnectionsModelBootstrapTests: XCTestCase {
    func testConcurrentBootstrapCallersAwaitSingleFlight() async {
        let barrier = BootstrapBarrier()
        let store = BootstrapConnectionStore()
        var preparations = 0
        var refreshes = 0
        var started = 0
        var completed = 0
        let model = ConnectionsModel(
            connectionStore: store,
            protocolDescriptors: [.ssh],
            descriptorProvider: { _ in .ssh },
            bootstrapPreparation: { preparations += 1 },
            keyRefresh: {
                refreshes += 1
                await barrier.wait()
            }
        )
        let callers = (0..<4).map { _ in
            Task { @MainActor in
                started += 1
                await model.bootstrap()
                completed += 1
            }
        }
        while started < 4 || !barrier.isWaiting { await Task.yield() }
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(refreshes, 1)
        let heldLoads = await store.loads
        XCTAssertEqual(heldLoads, 1)
        barrier.release()
        for caller in callers { await caller.value }
        XCTAssertEqual(completed, 4)
        await model.bootstrap()
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(refreshes, 1)
        let finalLoads = await store.loads
        XCTAssertEqual(finalLoads, 1)
    }
}

@MainActor
private final class BootstrapBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BootstrapConnectionStore: ConnectionStoreProtocol {
    private(set) var loads = 0
    func loadConnections() async throws(PersistenceError) -> [Connection] {
        loads += 1
        return []
    }
    func connection(id: UUID) async throws(PersistenceError) -> Connection? { nil }
    func save(_ connection: Connection) async throws(PersistenceError) {}
    func deleteConnection(id: UUID) async throws(PersistenceError) {}
}
