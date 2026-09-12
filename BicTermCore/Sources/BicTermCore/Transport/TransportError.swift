import Foundation

/// Typed errors surfaced by any ``TerminalTransport`` conformer and by
/// ``TransportRegistry`` resolution. Protocol implementations map their own
/// wire-level failures onto these cases; no protocol-specific error type
/// (and no generic `Error`) escapes the Transport layer.
///
/// The case list is deliberately small and protocol-agnostic: host-key
/// trust and authentication exist in every keyed remote-session protocol
/// (SSH today; ET/mosh later). `SSHTransportError` is a typealias of this
/// type so the SSH layer and the Sessions layer share one vocabulary.
public enum TransportError: Error, Equatable, Sendable {
    /// The presented host key differs from the trusted record. The
    /// connection is closed before any channel opens; no shell bytes are
    /// ever delivered.
    case hostKeyChanged(host: String, port: Int, oldFingerprint: String, newFingerprint: String)

    /// The host key is not yet trusted (TOFU). Carries everything the UI
    /// needs to present a trust prompt.
    case requiresTrust(fingerprint: String, algorithm: String, publicKeyData: Data)

    /// The server rejected the offered credential, or no usable credential
    /// exists.
    case authenticationFailed

    /// The host could not be reached, or the connection dropped without
    /// protocol-level diagnostics.
    case unreachable

    /// A channel/pty/shell request was denied, or the operation requires a
    /// connected transport.
    case channelDenied

    /// The connection's protocol is not available in this build (unknown
    /// or not-yet-implemented protocol id in persisted data). Resolution
    /// NEVER falls back to a different protocol silently.
    case protocolUnavailable(protocolID: String)

    /// `resume()` was called on a transport whose ``ResumeStrategy`` is
    /// `.rehandshake`. Resume for such transports means building a fresh
    /// transport from the factory (full handshake + auth), which the
    /// session layer drives — the instance itself cannot resume.
    case resumeUnsupported

    /// The protocol's control plane rejected the credential before any
    /// transport bytes flowed. Unlike ``authenticationFailed`` — an
    /// SSH-layer offer rejection — this case is for reauthentication UX,
    /// not a fresh key.
    case authRequired

    /// The session's backing identity no longer resolves (workspace deleted
    /// or not running, agent gone or ambiguous, server configuration
    /// removed); the connection record is stale.
    case reconnectRequired

    case remoteStartupFailed(state: String)
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .hostKeyChanged(host, port, oldFingerprint, newFingerprint):
            "Host key changed for \(host):\(port) from \(oldFingerprint) to \(newFingerprint)."
        case let .requiresTrust(fingerprint, algorithm, _):
            "Host key \(algorithm) \(fingerprint) requires explicit trust."
        case .authenticationFailed:
            "Authentication failed."
        case .unreachable:
            "The host is unreachable."
        case .channelDenied:
            "The session channel request was denied."
        case let .protocolUnavailable(protocolID):
            "Protocol \"\(protocolID)\" is not available in this build."
        case .resumeUnsupported:
            "This transport cannot resume in place; reconnect with a fresh handshake."
        case .authRequired:
            "The server rejected the stored credential. Reauthenticate to continue."
        case .reconnectRequired:
            "The remote workspace or agent is no longer available. Reconnect to resolve it again."
        case .remoteStartupFailed(let state):
            "Remote startup failed (\(state)). Review startup logs before retrying."
        }
    }
}
