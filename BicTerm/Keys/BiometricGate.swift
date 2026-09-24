import BicTermCore
import LocalAuthentication

protocol BiometricGate: Sendable {
    func authorize(reason: String) async -> Bool
}

enum BiometricGateFactory {
    static func make() -> BiometricGate {
        #if DEBUG
        if UITestArguments.isBiometricsBypassActive { return UITestBiometricGate() }
        #endif
        return LABiometricGate()
    }
}

/// Enforces `.deviceOwnerAuthenticationWithBiometrics` — biometrics only, no
/// passcode fallback, matching the plan's security policy.
struct LABiometricGate: BiometricGate {
    func authorize(reason: String) async -> Bool {
        BiometricAccessLog.log.notice(
            "key-management gate evaluation begin reason=\"\(reason, privacy: .public)\""
        )
        let context = LAContext()
        context.localizedReason = reason
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            BiometricAccessLog.log.error("key-management gate evaluation unavailable")
            return false
        }
        let ok = await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
        BiometricAccessLog.log.notice(
            "key-management gate evaluation \(ok ? "ok" : "denied", privacy: .public)"
        )
        return ok
    }
}

#if DEBUG
struct UITestBiometricGate: BiometricGate {
    func authorize(reason: String) async -> Bool { true }
}
#endif
