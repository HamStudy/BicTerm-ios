import XCTest

/// Holds a `BiometricEvaluationGate` turn until the test signals, with an
/// observable `held` flag for deterministic sequencing.
actor GateHold {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var held = false

    func wait() async {
        held = true
        await withCheckedContinuation { continuation in
            release = continuation
        }
    }

    func signal() {
        release?.resume()
        release = nil
    }
}

/// Records whether a task finished, so a test can assert completion (or
/// non-completion) while a gate turn is still held elsewhere.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

/// Polls `condition` until it returns true or the timeout elapses.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}
