import Foundation
import NIOCore
import NIOSSH

/// An established SSH connection that opens non-PTY exec channels.
/// ``SSHTransport`` (direct) and the jump-chain carrier conform, so herdr
/// consumers get exec channels regardless of hops. Each consumer (probe,
/// bridge, installer step) establishes its own connection — gateways that
/// permit one session channel per connection lifetime make a shared
/// connection unusable (see ``SSHTransport/connectExecOnly(to:)``).
public protocol SSHExecCapableConnection: Sendable {
    /// Opens a NEW non-PTY exec session channel on the established
    /// connection (same posture as ``SSHTransport/openExecChannel(command:)``).
    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession

    func close() async
}

extension SSHTransport: SSHExecCapableConnection {}

/// Non-PTY exec channel factory (T15, herdr remote-client-bridge) on
/// ``SSHTransport``, split out so the session-lifecycle file stays
/// reviewable on its own (same convention as SSHTransport+DirectTCPIP).
extension SSHTransport {
    /// Opens a NEW session channel on the live connection and runs
    /// `command` via `SSHChannelRequestEvent.ExecRequest` — no PTY, no
    /// shell request, no agent forwarding. Exec channels are
    /// `session`-type channels on the wire (RFC 4254), so on a connection
    /// established via ``SSHTransport/connectExecOnly(to:)`` this open is
    /// the connection's FIRST session channel. The interactive shell
    /// session (if one is established) is untouched: SSH multiplexes
    /// channels.
    ///
    /// The returned session owns its channel's lifecycle; closing it does
    /// not affect the connection or any sibling session.
    public func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        guard let parent = connectionChannel, parent.isActive else {
            // The typed contract carries no payload; capture the real
            // reason for the device diagnostic before the collapse.
            SSHEstablishDiagnostics.shared.record(
                "exec channel open: connection channel missing or inactive"
            )
            throw .channelDenied
        }

        let core = ExecChannelCore()
        let handler = ExecChannelHandler(core: core)
        let session: any Channel
        do {
            session = try await openChildChannel(on: parent, type: .session) { child, channelType in
                guard channelType == .session else {
                    return child.eventLoop.makeFailedFuture(TransportError.channelDenied)
                }
                return child.eventLoop.makeCompletedFuture {
                    // Remote EOF must arrive as an in-order half-close
                    // event, never a full channel close (NIOSSH default).
                    try child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    // Demand-driven reads: NIOSSH queues undelivered data
                    // and withholds the SSH receive window (lossless
                    // backpressure — see ExecChannelCore).
                    try child.setOption(ChannelOptions.autoRead, value: false)
                    core.attach(channel: child)
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? TransportError {
                throw error
            } else {
                // The typed contract carries no payload; capture the real
                // reason for the device diagnostic before the collapse.
                SSHEstablishDiagnostics.shared.record("exec channel open failed", error: error)
                throw .channelDenied
            }
        }

        // wantReply-tracked exec request: a refusal (e.g. the server's
        // session policy) surfaces as typed .channelDenied and never leaks
        // the opened channel.
        do {
            try await handler.sendRequestExpectingSuccess(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        } catch {
            // Force cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; do-block error type is exactly TransportError.
            let error = error as! TransportError
            // The typed contract carries no payload; capture the real
            // reason for the device diagnostic before the collapse.
            SSHEstablishDiagnostics.shared.record("exec channel request refused", error: error)
            try? await session.close().get()
            throw error
        }
        core.beginReading()
        return SSHExecSession(channel: session, handler: handler, core: core)
    }
}
