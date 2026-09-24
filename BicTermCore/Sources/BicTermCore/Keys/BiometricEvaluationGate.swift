import Foundation

/// Serializes biometric evaluations (Face ID / Touch ID) process-wide.
///
/// iOS performs one biometric evaluation at a time; a second evaluation begun
/// while one is in flight fails instead of queueing (device evidence: two
/// concurrent Secure Enclave / access-controlled-Keychain signatures, the
/// loser failing with a CryptoKit/Security error — see commit a844adf). The
/// gate converts that failure into waiting: ``enqueue`` suspends until every
/// earlier gated operation has finished, then runs its operation.
///
/// The gate adds waiting, not failure modes: errors from the operation
/// propagate unchanged, and the turn is always released — including when the
/// operation throws — so later operations are never starved.
///
/// Only biometry-protected key operations belong behind this gate;
/// non-biometric operations must not be serialized through it. The gate
/// lives at the async/await service boundary and must never be entered from
/// NIO event-loop threads.
public actor BiometricEvaluationGate {
    /// Biometric evaluation is a device-global resource, so every key
    /// service in the process funnels through one shared gate.
    public static let shared = BiometricEvaluationGate()

    /// True while some task owns the turn (running or about to run its
    /// gated operation). Ownership transfers directly to the next waiter on
    /// release, so this stays true across the hand-off.
    private var busy = false

    /// Suspended waiters, granted turns in FIFO order.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `operation` with exclusive process-wide access to biometric
    /// evaluation.
    ///
    /// Waiters are granted turns in the order the gate accepted their
    /// requests; among queued waiters the order is strictly FIFO. The
    /// operation runs on the calling task once the turn is granted — the
    /// gate itself never runs operation code, so a blocking biometric
    /// prompt cannot stall the actor. A task cancelled while waiting still
    /// receives its turn and runs its operation (matching the
    /// non-cancellable SecItem/Secure Enclave calls it wraps); errors —
    /// including `CancellationError` — propagate unchanged and always
    /// release the turn.
    public nonisolated func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await waitForTurn()
        BiometricAccessLog.log.notice("biometric gate: turn granted")
        do {
            let result = try await operation()
            await releaseTurn()
            return result
        } catch {
            await releaseTurn()
            throw error
        }
    }

    private func waitForTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            BiometricAccessLog.log.debug(
                "biometric gate: operation queued (\(self.waiters.count) waiting)"
            )
        }
    }

    private func releaseTurn() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Ownership transfers: `busy` stays true for the resumed waiter.
            next.resume()
        } else {
            busy = false
        }
        BiometricAccessLog.log.notice("biometric gate: turn released")
    }

    /// Number of operations currently waiting for the turn (test seam).
    var pendingWaiterCountForTesting: Int {
        waiters.count
    }
}
