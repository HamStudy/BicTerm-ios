import BicTermCore
import CryptoKit
import Foundation
import XCTest
@testable import BicTerm

// MARK: - Test doubles

/// Immediately resolves every authentication with the scripted outcome.
private final class ScriptedAuthClient: OwnerAuthenticationClient, @unchecked Sendable {
    // @unchecked Sendable: test double; immutable outcome.
    private let outcome: OwnerAuthenticationOutcome

    init(outcome: OwnerAuthenticationOutcome) {
        self.outcome = outcome
    }

    func authenticate(reason: String) async -> OwnerAuthenticationOutcome { outcome }
}

/// Pends every authentication until the test releases it (FIFO), recording
/// when the call reached the client so tests can sequence around the hop.
private final class PendedAuthClient: OwnerAuthenticationClient, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private var pended: [CheckedContinuation<OwnerAuthenticationOutcome, Never>] = []
    private var startedCount = 0

    func authenticate(reason: String) async -> OwnerAuthenticationOutcome {
        lock.withLock { startedCount += 1 }
        return await withCheckedContinuation { continuation in
            lock.withLock { pended.append(continuation) }
        }
    }

    var hasStartedCall: Bool { lock.withLock { startedCount > 0 } }
    var pendingCount: Int { lock.withLock { pended.count } }

    /// Resolves the OLDEST pended call — the stale-completion path releases
    /// the call that started FIRST.
    func releaseNext(_ outcome: OwnerAuthenticationOutcome) {
        lock.withLock {
            if !pended.isEmpty {
                pended.removeFirst().resume(returning: outcome)
            }
        }
    }
}

/// Settable LockStateProvider for driving the bridge's pre-enqueue
/// revalidation from app tests.
private final class TestLockState: LockStateProvider, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private var interactive: Bool
    private var generationValue: UInt64

    init(interactive: Bool = true, generation: UInt64 = 0) {
        self.interactive = interactive
        self.generationValue = generation
    }

    var isInteractive: Bool { lock.withLock { interactive } }
    var interactivityGeneration: UInt64 { lock.withLock { generationValue } }

    /// A true background transition: the generation advances (and the app
    /// stays or becomes non-interactive per the flag).
    func simulateBackgroundTransition(nowInteractive: Bool) {
        lock.withLock {
            generationValue += 1
            interactive = nowInteractive
        }
    }
}

/// Auto-approving prompt so service-level tests exercise the lock gate, not
/// the sheet.
private final class AutoApprovePrompt: AgentAuthorizationPrompt, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private var callCount = 0

    var promptCount: Int { lock.withLock { callCount } }

    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision {
        lock.withLock { callCount += 1 }
        return .allowForSession
    }
}

/// Real ed25519 key provider whose sign() fires a hook — the hook simulates
/// the background transition DURING signing.
private final class HookedSignKeyProvider: AgentKeyProvider, @unchecked Sendable {
    // @unchecked Sendable: test double; hook and counter guarded by NSLock.
    private let key = Curve25519.Signing.PrivateKey()
    let metadata: KeyMetadata
    private let lock = NSLock()
    private var onSign: (() -> Void)?
    private(set) var signCallCount = 0

    init(onSign: (() -> Void)? = nil) {
        let blob = SSHWireFormat.ed25519PublicKeyBlob(rawPublicKey: key.publicKey.rawRepresentation)
        self.metadata = KeyMetadata(
            reference: "applock-test-key",
            label: "applock test key",
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: blob),
            publicKeyBlob: blob,
            requiresBiometry: false
        )
        self.onSign = onSign
    }

    func publicKeys() async throws -> [KeyMetadata] { [metadata] }

    func sign(data: Data, publicKeyBlob: Data) async throws -> KeySignature {
        lock.withLock { signCallCount += 1 }
        onSign?()
        return KeySignature(algorithm: .ed25519, rawRepresentation: try key.signature(for: data))
    }
}

// MARK: - Tests

/// T10 app-lock policy: enable/disable, generation-based relock on true
/// background, owner-authentication outcomes, stale-completion rejection,
/// and the agent-authorization gate (cached denial while locked, pre-enqueue
/// revalidation after signing).
@MainActor
final class AppLockPolicyTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeRequest(fingerprint: String = "SHA256:applock") -> AgentAuthorizationRequest {
        AgentAuthorizationRequest(
            sessionID: "applock-session",
            host: "127.0.0.1",
            keyFingerprint: fingerprint,
            publicKeyBlob: Data([0x01, 0x02])
        )
    }

    // MARK: Enable / disable

    func testDefaultStateIsDisabledUnlockedAndIdle() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        XCTAssertFalse(state.isEnabled, "app lock must default OFF")
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.authStatus, .idle)
        XCTAssertEqual(state.generation, 0)
    }

    func testEnableDoesNotLockWhileUserIsPresent() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.isLocked, "enabling must not lock immediately — the user is present")
    }

    func testDisableClearsAnEngagedLock() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()
        state.noteDidEnterBackground()
        XCTAssertTrue(state.isLocked)
        state.disable()
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isLocked, "disabling must recover without authentication")
        XCTAssertEqual(state.authStatus, .idle)
    }

    // MARK: Relock on true background

    func testTrueBackgroundRelocksAndIncrementsGeneration() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()

        state.noteDidEnterBackground()
        XCTAssertTrue(state.isLocked, "a true background transition must engage the lock")
        XCTAssertEqual(state.generation, 1)

        state.noteDidEnterBackground()
        XCTAssertEqual(state.generation, 2, "every background transition increments the generation")
    }

    func testBackgroundTransitionIncrementsGenerationEvenWhenLockDisabled() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.noteDidEnterBackground()
        XCTAssertFalse(state.isLocked, "disabled lock never engages")
        XCTAssertEqual(state.generation, 1, "generation advances regardless — the agent gate revalidates against it")
    }

    /// Inactive-without-background (the system auth sheet, control center)
    /// must NOT relock: presenting LAContext itself makes the scene inactive.
    func testInactiveWithoutBackgroundDoesNotRelock() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)

        XCTAssertFalse(state.isLocked, "scene-inactive without background must not relock")
        XCTAssertEqual(state.generation, 0)
    }

    /// The production lifecycle wiring: the model itself observes the real
    /// UIApplication background notification.
    func testRealBackgroundNotificationRelocks() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertTrue(state.isLocked, "the real didEnterBackground notification must engage the lock")
        XCTAssertEqual(state.generation, 1)
    }

    // MARK: Authentication outcomes

    func testAuthenticationSuccessUnlocks() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()
        state.noteDidEnterBackground()
        XCTAssertTrue(state.isLocked)

        await state.authenticate(reason: "unlock")
        XCTAssertFalse(state.isLocked, "successful owner authentication unlocks")
        XCTAssertEqual(state.authStatus, .idle)
    }

    func testAuthenticationFailureKeepsLocked() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .failure))
        state.enable()
        state.noteDidEnterBackground()

        await state.authenticate(reason: "unlock")
        XCTAssertTrue(state.isLocked, "a wrong passcode must not unlock")
        XCTAssertEqual(state.authStatus, .failed)
    }

    func testAuthenticationCancelKeepsLocked() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .cancelled))
        state.enable()
        state.noteDidEnterBackground()

        await state.authenticate(reason: "unlock")
        XCTAssertTrue(state.isLocked, "a cancelled prompt must not unlock")
        XCTAssertEqual(state.authStatus, .cancelled)
    }

    func testAuthenticationUnavailableKeepsLocked() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .unavailable))
        state.enable()
        state.noteDidEnterBackground()

        await state.authenticate(reason: "unlock")
        XCTAssertTrue(state.isLocked, "unavailable owner authentication must not unlock")
        XCTAssertEqual(state.authStatus, .unavailable)
    }

    func testAuthenticationIsANoOpWhenLockDisabledOrAlreadyUnlocked() async {
        let client = ScriptedAuthClient(outcome: .success)
        let state = AppLockState(client: client)

        // Disabled: no authentication may even start.
        await state.authenticate(reason: "unlock")
        XCTAssertFalse(state.isLocked)

        // Enabled but unlocked (user present): still nothing to do.
        state.enable()
        await state.authenticate(reason: "unlock")
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.authStatus, .idle)
    }

    /// STALE completion: an authentication that resolves after a newer
    /// generation (the app backgrounded again mid-auth) is rejected.
    func testStaleAuthenticationCompletionIsRejected() async {
        let client = PendedAuthClient()
        let state = AppLockState(client: client)
        state.enable()
        state.noteDidEnterBackground()  // generation 1, locked

        async let auth: Void = state.authenticate(reason: "unlock")
        let started = await waitUntil { client.hasStartedCall }
        XCTAssertTrue(started, "authentication must reach the client")

        // The app backgrounds again while the sheet is up: generation 2
        // now owns the UI and the in-flight attempt is stale.
        state.noteDidEnterBackground()
        client.releaseNext(.success)

        await auth
        XCTAssertTrue(state.isLocked, "a stale success must not unlock")
        XCTAssertEqual(state.generation, 2)
    }

    // MARK: Agent authorization gate

    /// The production provider combines foreground-active with the app-lock
    /// state and mirrors the generation for the pre-enqueue revalidation.
    func testProviderCombinesActiveStateWithAppLock() {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let provider = ApplicationLockStateProvider(appLock: state)

        XCTAssertTrue(provider.isInteractive, "unlocked + active is interactive")
        XCTAssertEqual(provider.interactivityGeneration, 0)

        state.enable()
        state.noteDidEnterBackground()
        XCTAssertFalse(provider.isInteractive, "an engaged app lock makes the app noninteractive")
        XCTAssertEqual(provider.interactivityGeneration, 1, "the provider mirrors the lock generation")

        state.disable()
        XCTAssertTrue(provider.isInteractive, "disabling restores interactivity")
    }

    /// Cached agent approvals are DENIED while the app lock is engaged —
    /// the gate runs before the session-approval cache, with no sheet.
    func testCachedAgentApprovalDeniedWhileLocked() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let provider = ApplicationLockStateProvider(appLock: state)
        let prompt = AutoApprovePrompt()
        let service = AgentAuthorizationService(prompt: prompt, lockState: provider)
        let request = makeRequest()

        // Unlocked: approved for the session (cached).
        let first = await service.authorize(request)
        XCTAssertTrue(first)
        XCTAssertEqual(prompt.promptCount, 1)

        // Engage the lock: the cached approval must be denied outright.
        state.enable()
        state.noteDidEnterBackground()
        let cached = await service.authorize(request)
        XCTAssertFalse(cached, "a cached approval must not authorize while locked")
        XCTAssertEqual(prompt.promptCount, 1, "locked requests auto-deny without a sheet")

        // Unlocking restores the cached approval.
        state.disable()
        let restored = await service.authorize(request)
        XCTAssertTrue(restored)
        XCTAssertEqual(prompt.promptCount, 1, "the session cache survives the lock excursion")
    }

    // MARK: Pre-enqueue revalidation (background during sign)

    private func firstOpcode(_ response: Data) -> UInt8? {
        // Frame: uint32 length, then payload starting with the opcode.
        guard response.count >= 5 else { return nil }
        return response[response.startIndex + 4]
    }

    /// Background DURING signing (app left and returned): still interactive,
    /// but a newer generation — the sign response must NOT be enqueued.
    func testBackgroundDuringSignProducesNoSignatureResponse() async throws {
        let lockState = TestLockState(interactive: true, generation: 0)
        let service = AgentAuthorizationService(prompt: AutoApprovePrompt(), lockState: lockState)
        let provider = HookedSignKeyProvider(onSign: {
            lockState.simulateBackgroundTransition(nowInteractive: true)
        })
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: service,
            sessionID: "applock-sign",
            host: "127.0.0.1"
        )

        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: Data("payload".utf8), flags: 0)
        )
        XCTAssertEqual(
            firstOpcode(response),
            SSHAgentCodec.opcodeFailure,
            "a sign that crossed a background transition must answer FAILURE, never a signature"
        )
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 1, "the signature was produced — it just must not be returned")
    }

    /// Background DURING signing while the app STAYS backgrounded: not
    /// interactive and a newer generation — same denial.
    func testStillBackgroundedAfterSignProducesNoSignatureResponse() async {
        let lockState = TestLockState(interactive: true, generation: 0)
        let service = AgentAuthorizationService(prompt: AutoApprovePrompt(), lockState: lockState)
        let provider = HookedSignKeyProvider(onSign: {
            lockState.simulateBackgroundTransition(nowInteractive: false)
        })
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: service,
            sessionID: "applock-sign-bg",
            host: "127.0.0.1"
        )

        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: Data("payload".utf8), flags: 0)
        )
        XCTAssertEqual(firstOpcode(response), SSHAgentCodec.opcodeFailure)
    }

    /// Positive control: an uninterrupted foreground span still yields the
    /// signature response (the revalidation must not over-deny).
    func testUninterruptedSignStillProducesSignatureResponse() async throws {
        let lockState = TestLockState(interactive: true, generation: 0)
        let service = AgentAuthorizationService(prompt: AutoApprovePrompt(), lockState: lockState)
        let provider = HookedSignKeyProvider()
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: service,
            sessionID: "applock-sign-ok",
            host: "127.0.0.1"
        )

        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: Data("payload".utf8), flags: 0)
        )
        XCTAssertEqual(firstOpcode(response), SSHAgentCodec.opcodeSignResponse)
    }
}
