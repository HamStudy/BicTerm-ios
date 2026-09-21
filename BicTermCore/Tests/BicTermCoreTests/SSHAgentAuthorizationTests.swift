import Foundation
import XCTest
@testable import BicTermCore

private final class ScriptedPrompt: AgentAuthorizationPrompt, @unchecked Sendable {
    // @unchecked Sendable: test double; all state guarded by NSLock.
    private let lock = NSLock()
    private var decision: AgentAuthorizationDecision
    private var delay: Duration
    private(set) var recordedRequests: [AgentAuthorizationRequest] = []

    init(decision: AgentAuthorizationDecision, delay: Duration = .zero) {
        self.decision = decision
        self.delay = delay
    }

    var callCount: Int { lock.withLock { recordedRequests.count } }

    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision {
        let (current, delay) = lock.withLock { (decision, self.delay) }
        lock.withLock { recordedRequests.append(request) }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return current
    }
}

private struct FixedLockState: LockStateProvider {
    let isInteractive: Bool
    var interactivityGeneration: UInt64 { 0 }
}

private final class MutableLockState: LockStateProvider, @unchecked Sendable {
    // @unchecked Sendable: test double; flag guarded by NSLock.
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool) { value = initial }

    var isInteractive: Bool { lock.withLock { value } }
    var interactivityGeneration: UInt64 { 0 }

    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

final class SSHAgentAuthorizationTests: XCTestCase {
    private func makeRequest(
        sessionID: String = "session-1",
        host: String = "127.0.0.1",
        fingerprint: String = "SHA256:aaa"
    ) -> AgentAuthorizationRequest {
        AgentAuthorizationRequest(
            sessionID: sessionID,
            host: host,
            keyFingerprint: fingerprint,
            publicKeyBlob: Data("blob".utf8)
        )
    }

    func testAllowOncePermitsSingleRequestAndReprompts() async {
        let prompt = ScriptedPrompt(decision: .allowOnce)
        let service = AgentAuthorizationService(prompt: prompt, lockState: FixedLockState(isInteractive: true))
        let request = makeRequest()
        let first = await service.authorize(request)
        let second = await service.authorize(request)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(prompt.callCount, 2)
    }

    func testAllowForSessionSuppressesLaterPromptsForThatSessionOnly() async {
        let prompt = ScriptedPrompt(decision: .allowForSession)
        let service = AgentAuthorizationService(prompt: prompt, lockState: FixedLockState(isInteractive: true))
        let sameSessionFirst = await service.authorize(makeRequest(sessionID: "s1"))
        let sameSessionSecond = await service.authorize(makeRequest(sessionID: "s1"))
        XCTAssertTrue(sameSessionFirst)
        XCTAssertTrue(sameSessionSecond)
        XCTAssertEqual(prompt.callCount, 1)
        // A different session must prompt again.
        let otherSession = await service.authorize(makeRequest(sessionID: "s2"))
        XCTAssertTrue(otherSession)
        XCTAssertEqual(prompt.callCount, 2)
        // And a different key in the same session must prompt again.
        let otherKey = await service.authorize(makeRequest(sessionID: "s1", fingerprint: "SHA256:bbb"))
        XCTAssertTrue(otherKey)
        XCTAssertEqual(prompt.callCount, 3)
    }

    func testDenyNeverCaches() async {
        let prompt = ScriptedPrompt(decision: .deny)
        let service = AgentAuthorizationService(prompt: prompt, lockState: FixedLockState(isInteractive: true))
        let request = makeRequest()
        let first = await service.authorize(request)
        let second = await service.authorize(request)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(prompt.callCount, 2)
    }

    func testBackgroundedAppRejectsSignRequest() async {
        let prompt = ScriptedPrompt(decision: .allowForSession)
        let service = AgentAuthorizationService(prompt: prompt, lockState: FixedLockState(isInteractive: false))
        let allowed = await service.authorize(makeRequest())
        XCTAssertFalse(allowed)
        XCTAssertEqual(prompt.callCount, 0)
    }

    func testBackgroundingInvalidatesSessionApproval() async {
        let prompt = ScriptedPrompt(decision: .allowForSession)
        let lock = MutableLockState(true)
        let service = AgentAuthorizationService(prompt: prompt, lockState: lock)
        let request = makeRequest()
        let foreground = await service.authorize(request)
        XCTAssertTrue(foreground)
        lock.set(false)
        let backgrounded = await service.authorize(request)
        XCTAssertFalse(backgrounded)
        XCTAssertEqual(prompt.callCount, 1)
        lock.set(true)
        // Foreground again: the session approval is still valid (the gesture
        // was for the session; the background window did not revoke it).
        let foregroundAgain = await service.authorize(request)
        XCTAssertTrue(foregroundAgain)
        XCTAssertEqual(prompt.callCount, 1)
    }

    func testRequestFloodIsBounded() async {
        // Slow prompt forces queueing so the pending bound actually engages.
        let prompt = ScriptedPrompt(decision: .deny, delay: .milliseconds(5))
        let service = AgentAuthorizationService(
            prompt: prompt,
            lockState: FixedLockState(isInteractive: true),
            maxConcurrentPrompts: 1,
            maxPendingRequests: 16
        )
        let request = makeRequest()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<1000 {
                group.addTask { await service.authorize(request) }
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        XCTAssertEqual(results.count, 1000)
        XCTAssertTrue(results.allSatisfy { !$0 })
        // Prompts are bounded by the pending cap, not the flood size.
        XCTAssertLessThanOrEqual(prompt.callCount, 17)
        XCTAssertGreaterThan(prompt.callCount, 0)
    }

    func testConcurrentAllowForSessionPromptsAtMostOncePerKey() async {
        let prompt = ScriptedPrompt(decision: .allowForSession, delay: .milliseconds(20))
        let service = AgentAuthorizationService(prompt: prompt, lockState: FixedLockState(isInteractive: true))
        let request = makeRequest()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { await service.authorize(request) }
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 })
        // Serialized prompts + post-wait cache re-check: the first waiter
        // records the approval, the rest see it without prompting.
        XCTAssertLessThanOrEqual(prompt.callCount, 2)
    }
}
