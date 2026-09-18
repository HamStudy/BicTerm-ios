import XCTest
@testable import BicTermCore

final class BiometricEvaluationGateTests: XCTestCase {
    private struct GatedFailure: Error {}

    private actor InFlightTracker {
        private var active = 0
        private(set) var maxInFlight = 0

        func begin() {
            active += 1
            maxInFlight = max(maxInFlight, active)
        }

        func end() {
            active -= 1
        }
    }

    private actor OrderRecorder {
        private(set) var recorded: [Int] = []

        func record(_ index: Int) {
            recorded.append(index)
        }
    }

    func testConcurrentGatedOperationsNeverOverlap() async throws {
        let gate = BiometricEvaluationGate()
        let tracker = InFlightTracker()
        let operations = (0..<8).map { _ in
            Task {
                try await gate.enqueue {
                    await tracker.begin()
                    try await Task.sleep(nanoseconds: 10_000_000)
                    await tracker.end()
                }
            }
        }

        for operation in operations {
            try await operation.value
        }

        let maxInFlight = await tracker.maxInFlight
        XCTAssertEqual(maxInFlight, 1, "gated operations must never overlap")
    }

    func testThrowingOperationReleasesGateForLaterOperations() async throws {
        let gate = BiometricEvaluationGate()

        do {
            try await gate.enqueue { throw GatedFailure() }
            XCTFail("expected the gated operation to throw")
        } catch is GatedFailure {}

        let value = try await gate.enqueue { 41 + 1 }
        XCTAssertEqual(value, 42)
    }

    func testThrowingWaiterDoesNotStarveLaterWaiters() async throws {
        let gate = BiometricEvaluationGate()
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let failing = Task {
            try await gate.enqueue { throw GatedFailure() }
        }
        let failingQueued = await waitUntil { await gate.pendingWaiterCountForTesting >= 1 }
        XCTAssertTrue(failingQueued, "failing operation never queued")
        let succeeding = Task {
            try await gate.enqueue { "ran after the failure" }
        }
        let succeedingQueued = await waitUntil { await gate.pendingWaiterCountForTesting >= 2 }
        XCTAssertTrue(succeedingQueued, "succeeding operation never queued")

        await hold.signal()
        _ = try? await holder.value

        do {
            _ = try await failing.value
            XCTFail("expected the queued failing operation to throw")
        } catch is GatedFailure {}
        let result = try await succeeding.value
        XCTAssertEqual(result, "ran after the failure")
    }

    func testWaitersAreGrantedTurnsInFIFOOrder() async throws {
        let gate = BiometricEvaluationGate()
        let hold = GateHold()
        let order = OrderRecorder()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        var waiters: [Task<Void, Error>] = []
        for index in 0..<3 {
            waiters.append(Task {
                try await gate.enqueue {
                    await order.record(index)
                }
            })
            let waiterQueued = await waitUntil { await gate.pendingWaiterCountForTesting >= index + 1 }
            XCTAssertTrue(waiterQueued, "waiter \(index) never queued")
        }

        await hold.signal()
        _ = try? await holder.value
        for waiter in waiters {
            _ = try? await waiter.value
        }

        let recorded = await order.recorded
        XCTAssertEqual(recorded, [0, 1, 2], "waiters must be granted turns in FIFO order")
    }
}
