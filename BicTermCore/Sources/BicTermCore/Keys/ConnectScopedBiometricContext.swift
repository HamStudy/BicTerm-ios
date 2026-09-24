import Foundation
import LocalAuthentication

/// ONE biometric evaluation shared by every key operation of a single
/// connect action.
///
/// A connect action (terminal connect, jump-chain build, herdr bring-up,
/// herd open) may resolve MANY biometry-protected keys — the SSH
/// cascade's offers, a jump chain's hops, a herd's machines, the herdr
/// probe and bridge handshakes. Before this type each resolution built a
/// FRESH `LAContext`, so each one triggered its own Face ID evaluation
/// (device evidence: ~4 sequential evaluations, all `operation:od`, same
/// key ACL, fresh context each). Threading ONE context per connect
/// action collapses them: the first biometry-protected operation of the
/// action evaluates the context (the ONE prompt), and every later
/// operation reuses the already-authenticated context — Keychain reads
/// via `kSecUseAuthenticationContext`, Secure Enclave signatures via the
/// context the key retains at construction.
///
/// ``authorize(reason:)`` must run inside a
/// ``BiometricEvaluationGate``-serialized operation: the gate is what
/// serializes biometric evaluations process-wide (a second evaluation
/// begun while one is in flight FAILS on iOS rather than queueing), and
/// it is what makes `authorize`'s check-then-evaluate sequence race-free
/// — two gated operations cannot interleave between the
/// ``isEvaluated`` check and the evaluation.
///
/// `LAContext` is not declared `Sendable`, but the instance is only
/// ever handed to Apple's evaluation machinery (Keychain query, Secure
/// Enclave key construction, `evaluatePolicy`); BicTerm never mutates it
/// apart from `localizedReason`, so unchecked conformance is safe. The
/// evaluated flag is lock-confined.
public final class ConnectScopedBiometricContext: @unchecked Sendable {
    /// The biometric policy evaluation over the wrapped context.
    /// Production: `LAContext.evaluatePolicy`. Test seam: a deterministic
    /// stand-in (counting, parking, failing).
    public typealias Evaluation = @Sendable (_ context: LAContext, _ reason: String) async throws -> Void

    private static let systemEvaluation: Evaluation = { context, reason in
        context.localizedReason = reason
        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    }

    /// The shared context: handed to Keychain queries
    /// (`kSecUseAuthenticationContext`) and Secure Enclave key
    /// construction. Internal so the key services (same module) can
    /// attach it; never crosses the module boundary.
    ///
    /// `touchIDAuthenticationAllowableReuseDuration` is set so later
    /// operations of the SAME connect action — every Secure Enclave
    /// handshake signature that consumes the retained context, every
    /// Keychain read that attaches it — are credited with the one
    /// evaluation's pass. Without it, iOS may re-prompt once the initial
    /// authentication ages out of the context (the reuse credit only
    /// applies WITHIN a single LAContext instance, which is exactly why
    /// the pre-fix fresh-context-per-resolution shape prompted every
    /// time). 60 s covers a connect action and a realistic herd bring-up
    /// (machines establish serially); a slower bring-up re-prompting
    /// after the window matches the "each new connect action evaluates
    /// fresh" rule.
    let context: LAContext = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 60
        return context
    }()

    private let lock = NSLock()
    private var evaluated = false
    private let evaluate: Evaluation

    public init() {
        self.evaluate = Self.systemEvaluation
    }

    /// Test seam: deterministic evaluation (same shape as
    /// ``SecureEnclaveKeyService/opaqueRepresentationForTesting`` — a
    /// public seam because the app-hosted test bundle, which holds the
    /// Keychain entitlement, imports BicTermCore without @testable).
    public init(evaluate: @escaping Evaluation) {
        self.evaluate = evaluate
    }

    /// True once a biometric evaluation succeeded for this context.
    public var isEvaluated: Bool {
        lock.withLock { evaluated }
    }

    /// Evaluates the context's biometric policy exactly ONCE per connect
    /// action: the first call runs the evaluation (the ONE Face ID
    /// prompt); every later call returns immediately, and the operations
    /// that follow ride the already-authenticated context. A failed
    /// evaluation (user cancellation, biometry unavailable) propagates
    /// and leaves the context un-evaluated, so a retry re-prompts.
    ///
    /// - Requires: called from inside a ``BiometricEvaluationGate``
    ///   operation (see class docs).
    public func authorize(reason: String) async throws {
        guard !isEvaluated else {
            BiometricAccessLog.log.debug(
                "biometric evaluation skipped — context already authenticated"
            )
            return
        }
        BiometricAccessLog.log.notice(
            "biometric evaluation begin reason=\"\(reason, privacy: .public)\""
        )
        do {
            try await evaluate(context, reason)
        } catch {
            BiometricAccessLog.log.error(
                "biometric evaluation failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        lock.withLock { evaluated = true }
        BiometricAccessLog.log.notice("biometric evaluation ok")
    }
}
