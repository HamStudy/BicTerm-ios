import Foundation

/// Typed errors surfaced by ``SSHTransport``. Every failure of the transport
/// maps to exactly one of these cases; no generic `Error` escapes.
public enum SSHTransportError: Error, Equatable, Sendable {
    /// The presented host key differs from the trusted record. Connection is
    /// closed before any channel opens; no shell bytes are ever delivered.
    case hostKeyChanged(host: String, port: Int, oldFingerprint: String, newFingerprint: String)

    /// The host key is not yet trusted (TOFU). Carries everything the UI
    /// needs to present a trust prompt; trusting is done via
    /// `HostKeyVerifier.trust`, then reconnect.
    case requiresTrust(fingerprint: String, algorithm: String, publicKeyData: Data)

    /// The server rejected the offered public key, or no usable key exists.
    case authenticationFailed

    /// TCP connection could not be established, or the connection dropped
    /// before/without SSH-level diagnostics.
    case unreachable

    /// A channel request was denied: session open refused, pty/shell request
    /// failed, direct-tcpip rejected, or the transport is not connected.
    case channelDenied
}

extension SSHTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .hostKeyChanged(host, port, oldFingerprint, newFingerprint):
            "Host key changed for \(host):\(port) from \(oldFingerprint) to \(newFingerprint)."
        case let .requiresTrust(fingerprint, algorithm, _):
            "Host key \(algorithm) \(fingerprint) requires explicit trust."
        case .authenticationFailed:
            "SSH public-key authentication failed."
        case .unreachable:
            "The host is unreachable."
        case .channelDenied:
            "The SSH channel request was denied."
        }
    }
}
