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
        let context = LAContext()
        context.localizedReason = reason
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

#if DEBUG
struct UITestBiometricGate: BiometricGate {
    func authorize(reason: String) async -> Bool { true }
}
#endif
