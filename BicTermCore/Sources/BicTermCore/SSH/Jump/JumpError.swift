import Foundation

/// Typed errors surfaced by ``JumpChainBuilder``. Every failure of a jump
/// chain maps to exactly one of these cases; no generic `Error` escapes.
public enum JumpError: Error, Equatable, Sendable {
    /// A hop in the chain failed. `hopIndex` is 1-BASED over the full
    /// sequence `[jumpChain..., destination]`: hop 1 is the first jump host
    /// (or the destination itself for a direct connection), and for a
    /// two-host chain the final destination is hop 2. `underlying` is the
    /// typed transport error that killed the hop (host-key, auth,
    /// reachability, channel refusal).
    case hopFailed(hopIndex: Int, host: String, port: Int, underlying: SSHTransportError)

    /// The same (host, port) appears twice across the jump chain and the
    /// destination — a cyclic chain can never make progress.
    case cycleDetected(host: String, port: Int)

    /// The chain exceeds the hard bound (`Connection.maximumJumpChainLength`).
    /// The T2 model enforces this too; the builder re-asserts it defensively.
    case tooManyHops(maximum: Int, actual: Int)
}

extension JumpError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .hopFailed(hopIndex, host, port, underlying):
            "Jump hop \(hopIndex) (\(host):\(port)) failed: \(underlying.localizedDescription)"
        case let .cycleDetected(host, port):
            "Jump chain is cyclic: \(host):\(port) appears more than once."
        case let .tooManyHops(maximum, actual):
            "Jump chain has \(actual) hops; the maximum is \(maximum)."
        }
    }
}
