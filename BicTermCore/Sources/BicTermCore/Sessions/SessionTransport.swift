import Foundation

/// T11 unified the interim transport seams into ``TerminalTransport``
/// (Transport/). These typealiases keep the Sessions vocabulary compiling
/// unchanged; new code should use the Transport/ names directly.
public typealias SessionTransportError = TransportError
public typealias SessionTransport = TerminalTransport
public typealias SessionTransportFactory = TerminalTransportFactory

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
