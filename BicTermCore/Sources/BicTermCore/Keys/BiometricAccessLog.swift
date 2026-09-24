import CryptoKit
import Foundation
import os

/// Biometric-access instrumentation for device captures: every site that
/// can trigger a Face ID / Touch ID evaluation logs its call site, a
/// stable digest of the key reference, the prompt reason, and the
/// outcome — never key material, signatures, or secrets.
///
/// Capture on device with:
///
///     log stream --predicate 'subsystem == "com.bicterm.app" AND
///         category == "biometrics"'
///
/// The digest exists for log correlation: the reference itself is a UUID
/// (not secret), but a short stable hash keeps device logs compact and
/// prevents reference harvesting from shared captures.
public enum BiometricAccessLog {
    public static let log = Logger(subsystem: "com.bicterm.app", category: "biometrics")

    /// Stable 8-hex-char digest of a key reference.
    public static func referenceDigest(_ reference: String) -> String {
        SHA256.hash(data: Data(reference.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
