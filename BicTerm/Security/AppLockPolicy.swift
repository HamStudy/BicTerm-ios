import Foundation
import LocalAuthentication
import Observation
import UIKit

/// Outcome of one owner-authentication attempt.
enum OwnerAuthenticationOutcome: Equatable, Sendable {
    case success
    /// Wrong passcode / biometric mismatch — retryable, stays locked.
    case failure
    /// The user cancelled the prompt — stays locked.
    case cancelled
    /// Owner authentication cannot run (no passcode set, system error) —
    /// stays locked; the UI must offer a recoverable path.
    case unavailable
}

/// Injected owner-authentication client. Production uses LAContext with
/// `.deviceOwnerAuthentication` — biometrics WITH passcode fallback, never
/// biometrics-only (that stricter policy belongs to the per-key
/// `BiometricGate` and must not change).
protocol OwnerAuthenticationClient: Sendable {
    func authenticate(reason: String) async -> OwnerAuthenticationOutcome
}

/// Production client: `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`.
struct LAContextOwnerAuthenticationClient: OwnerAuthenticationClient {
    func authenticate(reason: String) async -> OwnerAuthenticationOutcome {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return .unavailable
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: Self.outcome(success: success, error: error))
            }
        }
    }

    private static func outcome(success: Bool, error: Error?) -> OwnerAuthenticationOutcome {
        if success { return .success }
        switch (error as? LAError)?.code {
        case .authenticationFailed:
            return .failure
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled
        default:
            return .unavailable
        }
    }
}

/// Thread-safe mirror of the lock status for non-main-actor readers. The
/// agent authorization hot path (`ApplicationLockStateProvider`) reads it
/// synchronously from the agent actor, so `AppLockState` updates it in the
/// same synchronous MainActor step as every mutation.
final class AppLockStatusMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var generationValue: UInt64 = 0

    var isLocked: Bool { lock.withLock { locked } }
    var generation: UInt64 { lock.withLock { generationValue } }

    func update(isLocked: Bool, generation: UInt64) {
        lock.withLock {
            locked = isLocked
            generationValue = generation
        }
    }
}

/// App-lock policy state: default OFF. While enabled, every true background
/// transition engages the lock; owner authentication unlocks exactly the
/// generation it completes in. The generation advances on EVERY background
/// transition (enabled or not) so in-flight authentications and agent
/// authorizations are invalidated by a background excursion even when the
/// lock itself is disabled.
@MainActor
@Observable
final class AppLockState {
    enum AuthStatus: Equatable {
        case idle
        case authenticating
        case failed
        case cancelled
        case unavailable
    }

    private(set) var isEnabled = false
    private(set) var isLocked = false
    private(set) var authStatus: AuthStatus = .idle
    private(set) var generation: UInt64 = 0

    /// Lock status as seen off the main actor (agent authorization gate).
    let statusMirror = AppLockStatusMirror()

    private let client: any OwnerAuthenticationClient
    /// Generation of the authentication attempt currently in flight; nil
    /// when none is. A background transition abandons the slot so a newer
    /// attempt can start; the abandoned attempt's completion is then
    /// rejected as superseded.
    private var inFlightGeneration: UInt64?
    /// Observer tokens; written only on the main actor, read by `deinit`
    /// (nonisolated by nature) after the last reference drops.
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

    init(client: (any OwnerAuthenticationClient)? = nil) {
        self.client = client ?? AppLockClientFactory.make()
        observeLifecycle()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Enable / disable

    /// Enabling never locks immediately — the user toggling the setting is
    /// present by definition; the first background transition engages it.
    func enable() {
        isEnabled = true
    }

    /// Disabling is the no-authentication recovery path: it clears an
    /// engaged lock and abandons any in-flight authentication.
    func disable() {
        isEnabled = false
        isLocked = false
        authStatus = .idle
        inFlightGeneration = nil
        statusMirror.update(isLocked: false, generation: generation)
    }

    // MARK: Lifecycle

    /// True background transition (`didEnterBackground`). Inactive-without-
    /// background — the system authentication sheet, control center, an
    /// incoming call — must NOT relock: presenting LAContext itself makes
    /// the scene inactive, and locking on that would deadlock the unlock
    /// flow. Directly callable so tests drive the transition without
    /// UIKit notifications.
    func noteDidEnterBackground() {
        generation += 1
        inFlightGeneration = nil
        if isEnabled {
            isLocked = true
            authStatus = .idle
        }
        statusMirror.update(isLocked: isLocked, generation: generation)
    }

    // MARK: Authentication

    /// Requests owner authentication for the current generation. A
    /// completion that resolves after a newer generation (the app
    /// backgrounded again) is rejected as stale and never unlocks.
    func authenticate(reason: String) async {
        guard isEnabled, isLocked, inFlightGeneration == nil else { return }
        let capturedGeneration = generation
        inFlightGeneration = capturedGeneration
        authStatus = .authenticating

        let outcome = await client.authenticate(reason: reason)

        // A newer attempt owns the slot (or a background transition cleared
        // it): this completion is superseded and must not touch state.
        guard inFlightGeneration == capturedGeneration else { return }
        inFlightGeneration = nil

        // Stale: the app backgrounded while the sheet was up. The result
        // belongs to a generation the user can no longer observe.
        guard generation == capturedGeneration else {
            authStatus = .idle
            return
        }

        switch outcome {
        case .success:
            isLocked = false
            authStatus = .idle
            statusMirror.update(isLocked: false, generation: generation)
        case .failure:
            authStatus = .failed
        case .cancelled:
            authStatus = .cancelled
        case .unavailable:
            authStatus = .unavailable
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteDidEnterBackground()
            }
        })
    }
}

/// Selects the owner-authentication client. Production always uses LAContext;
/// the DEBUG pended fake is chosen only by the UI-test launch argument
/// (same factory shape as `BiometricGateFactory`).
enum AppLockClientFactory {
    static func make() -> any OwnerAuthenticationClient {
        #if DEBUG
        if AppLockUITestSeam.isActive {
            return AppLockUITestSeam.sharedClient
        }
        #endif
        return LAContextOwnerAuthenticationClient()
    }
}

#if DEBUG
/// DEBUG-only launch-controlled fake owner-authentication client
/// (`--uitest-applock-pend`): every `authenticate` call pends until the
/// UI-test overlay releases it, FIFO, with a chosen outcome. Real LAContext
/// cannot run in simulator tests — this client is the deterministic driver
/// through the production `AppLockState` code path.
final class PendedOwnerAuthenticationClient: OwnerAuthenticationClient, @unchecked Sendable {
    // @unchecked Sendable: DEBUG test double; state guarded by NSLock.
    private let lock = NSLock()
    private var pended: [CheckedContinuation<OwnerAuthenticationOutcome, Never>] = []

    func authenticate(reason: String) async -> OwnerAuthenticationOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock { pended.append(continuation) }
        }
    }

    var pendingCount: Int { lock.withLock { pended.count } }

    /// Releases the OLDEST pended call — the stale-completion scenarios
    /// release the attempt that started first.
    func releaseNext(_ outcome: OwnerAuthenticationOutcome) {
        lock.withLock {
            if !pended.isEmpty {
                pended.removeFirst().resume(returning: outcome)
            }
        }
    }
}
#endif
