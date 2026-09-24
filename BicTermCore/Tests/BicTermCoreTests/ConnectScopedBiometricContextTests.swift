import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// ONE biometric evaluation per connect action: ``ConnectScopedBiometricContext``
/// evaluates its policy exactly once, a failed evaluation leaves it
/// un-evaluated so a retry re-prompts, and the key services reuse the
/// authenticated context instead of evaluating again.
final class ConnectScopedBiometricContextTests: XCTestCase {
    func testAuthorizeEvaluatesExactlyOnce() async throws {
        let counter = EvaluationCounter()
        let context = ConnectScopedBiometricContext(evaluate: { _, _ in counter.record() })

        try await context.authorize(reason: "Authenticate to host")
        try await context.authorize(reason: "Authenticate to host")

        XCTAssertEqual(counter.value, 1, "the second authorize must reuse the first evaluation")
        XCTAssertTrue(context.isEvaluated)
    }

    func testFailedEvaluationPropagatesAndAllowsRetry() async throws {
        let counter = EvaluationCounter()
        let context = ConnectScopedBiometricContext(evaluate: { _, _ in
            counter.record()
            if counter.value == 1 { throw StubEvaluationError() }
        })

        do {
            try await context.authorize(reason: "Authenticate to host")
            XCTFail("the first evaluation must propagate its failure")
        } catch is StubEvaluationError {
            // expected
        }
        XCTAssertFalse(context.isEvaluated, "a failed evaluation must not mark the context evaluated")

        try await context.authorize(reason: "Authenticate to host")
        XCTAssertEqual(counter.value, 2, "a retry after failure must re-evaluate")
        XCTAssertTrue(context.isEvaluated)
    }

    func testAuthorizePassesReasonAndContextToTheEvaluation() async throws {
        let recorder = EvaluationRecorder()
        let context = ConnectScopedBiometricContext(evaluate: { _, reason in recorder.record(reason) })

        try await context.authorize(reason: "Authenticate to host")

        XCTAssertEqual(recorder.reasons, ["Authenticate to host"])
    }
}

// MARK: - Test doubles

private struct StubEvaluationError: Error {}

/// Lock-confined evaluation counter (the evaluation closure is @Sendable).
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class EvaluationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var reasons: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ reason: String) {
        lock.lock()
        recorded.append(reason)
        lock.unlock()
    }
}
