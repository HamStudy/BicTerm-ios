import Foundation

/// Typed errors surfaced by any ``SessionTransport`` conformer. Protocol
/// implementations map their own transport errors (e.g. T7's
/// `SSHTransportError`) onto these cases; no generic `Error` escapes the
/// Sessions layer.
///
/// T11 (TerminalTransport) will unify this seam with the SSH/Jump layer —
/// keep the case list small and protocol-agnostic.
public enum SessionTransportError: Error, Equatable, Sendable {
    /// The presented host key differs from the trusted record.
    case hostKeyChanged(host: String, port: Int, oldFingerprint: String, newFingerprint: String)

    /// The host key is not yet trusted (TOFU). Carries everything the UI
    /// needs to present a trust prompt.
    case requiresTrust(fingerprint: String, algorithm: String, publicKeyData: Data)

    /// The server rejected the offered key, or no usable key exists.
    case authenticationFailed

    /// The host could not be reached, or the connection dropped without
    /// protocol-level diagnostics.
    case unreachable

    /// A channel/pty/shell request was denied, or the transport is not
    /// connected.
    case channelDenied

    /// Maps T7's typed SSH errors onto the Sessions-level seam.
    public init(_ error: SSHTransportError) {
        switch error {
        case let .hostKeyChanged(host, port, oldFingerprint, newFingerprint):
            self = .hostKeyChanged(
                host: host,
                port: port,
                oldFingerprint: oldFingerprint,
                newFingerprint: newFingerprint
            )
        case let .requiresTrust(fingerprint, algorithm, publicKeyData):
            self = .requiresTrust(
                fingerprint: fingerprint,
                algorithm: algorithm,
                publicKeyData: publicKeyData
            )
        case .authenticationFailed:
            self = .authenticationFailed
        case .unreachable:
            self = .unreachable
        case .channelDenied:
            self = .channelDenied
        }
    }
}

extension SessionTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .hostKeyChanged(host, port, oldFingerprint, newFingerprint):
            "Host key changed for \(host):\(port) from \(oldFingerprint) to \(newFingerprint)."
        case let .requiresTrust(fingerprint, algorithm, _):
            "Host key \(algorithm) \(fingerprint) requires explicit trust."
        case .authenticationFailed:
            "Public-key authentication failed."
        case .unreachable:
            "The host is unreachable."
        case .channelDenied:
            "The session channel request was denied."
        }
    }
}

/// The transport contract ``SessionRegistry`` drives. One instance ==
/// one connection attempt: reconnect means a FRESH instance from the
/// factory (fresh TCP + handshake + auth), never re-handshaking on a
/// stale instance.
///
/// `output` is per-instance: it finishes when the connection drops or
/// `close()` is called. The registry bridges per-instance streams into a
/// stable per-session stream, so consumers subscribe exactly once.
public protocol SessionTransport: Sendable {
    var output: AsyncStream<Data> { get async }
    func connect(to connection: Connection, cols: Int, rows: Int) async throws(SessionTransportError)
    func send(_ bytes: Data) async throws(SessionTransportError)
    func resize(cols: Int, rows: Int) async
    func close() async
}

/// Produces fresh transports, one per (re)connection attempt.
public protocol SessionTransportFactory: Sendable {
    func makeTransport() -> any SessionTransport
}

/// Bounded reconnect policy for drop-triggered automatic reconnects.
/// Delays grow geometrically: attempt N waits
/// `initialDelay * backoffMultiplier^(N-1)` before connecting.
public struct ReconnectPolicy: Equatable, Sendable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var backoffMultiplier: Double

    public init(
        maxAttempts: Int = 4,
        initialDelay: Duration = .seconds(1),
        backoffMultiplier: Double = 2
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.backoffMultiplier = max(1, backoffMultiplier)
    }

    public static let `default` = ReconnectPolicy()

    public func delay(forAttempt attempt: Int) -> Duration {
        var delay = initialDelay
        for _ in 1..<max(attempt, 1) {
            delay = scaled(delay, by: backoffMultiplier)
        }
        return delay
    }

    private func scaled(_ duration: Duration, by factor: Double) -> Duration {
        let components = duration.components
        let attoseconds = components.seconds &* 1_000_000_000_000_000_000 &+ components.attoseconds
        let scaled = Int64((Double(attoseconds) * factor).rounded())
        return Duration(
            secondsComponent: scaled / 1_000_000_000_000_000_000,
            attosecondsComponent: scaled % 1_000_000_000_000_000_000
        )
    }
}
