import Foundation

/// Typed failures of the Coder tailnet-tunnel bridge. The Go core collapses
/// every start failure (bad JSON, missing fields, unroutable server URL)
/// onto its `0` handle sentinel; the boundary maps that sentinel here. Finer
/// diagnostics travel over the bridge's log channel, not this error.
public enum CoderTunnelError: Error, Equatable, Sendable {
    /// `CoderNetStart` returned the rejection sentinel `0` — the config JSON
    /// was rejected at the boundary. No session was allocated.
    case startRejected
}

/// Dependency-inverted contract for the Coder workspace-SSH tunnel core.
///
/// This protocol is the ONLY surface BicTermCore knows about: it is pure
/// Swift, imports nothing beyond Foundation, and keeps the AGPL-licensed Go
/// core (`CoderNet.xcframework`, built from `CoderNet/bridge.go` on top of
/// coder/coder v2) out of the core module. The sole production conformer is
/// `CoderNetTunnel` in the `CoderTunnel` framework target, which AppStore
/// build configurations exclude entirely; capability detection is expressed
/// through ``ProtocolDescriptor/supportsTailnetTunnel``.
///
/// Handle ownership mirrors the C ABI:
/// - ``start(configJSON:)`` allocates a session handle; return values are
///   positive, increasing, and unique for the lifetime of the process.
///   Handle `0` is the bridge's rejection sentinel and never escapes — a
///   rejected start throws ``CoderTunnelError/startRejected``.
/// - ``close(handle:)`` releases the session. It is terminal and idempotent
///   (the bridge treats unknown handles as a logged no-op).
/// - ``rebind(handle:)`` re-anchors a live session to the current network
///   path after interface changes (tailnet rebinding); a no-op until T9
///   wires `DialAgent`.
///
/// The `async` requirements let conformers hop off the caller's executor —
/// the real conformer blocks on synchronous FFI into the Go runtime and MUST
/// NOT run on the main actor.
public protocol CoderTunneling: Sendable {
    /// Bridge version banner, e.g. `CoderNet-BicTerm/0.1`. Mirrors
    /// `CoderNetVersion()`; never throws, an empty string means the bridge
    /// could not produce one.
    func version() -> String

    /// Parse-retain one tunnel session from a JSON config of the shape
    /// `{server_url, session_token, agent_id, relay_only}`. Returns the
    /// allocated handle. Throws ``CoderTunnelError/startRejected`` when the
    /// bridge rejects the config.
    func start(configJSON: String) async throws(CoderTunnelError) -> Int

    /// Open the workspace-agent SSH channel for a started handle and return
    /// its stream metadata (T5 stub: empty string until T9 types the channel).
    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String

    /// Rebind a live session's network path (interface change / roaming).
    func rebind(handle: Int)

    /// Release a session handle. Terminal and idempotent.
    func close(handle: Int)
}
