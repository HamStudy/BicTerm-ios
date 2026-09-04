import Foundation

/// The session-facing surface of an established SSH connection, direct or
/// jumped. The terminal/session layer consumes ONLY this protocol — it never
/// knows whether hops exist. `SSHTransport` (direct) and `JumpTransport`
/// (jumped) both conform.
public protocol SSHSessionTransport: Sendable {
    /// Fresh per connection; bounded at 32 chunks of ≤32 KiB, oldest dropped
    /// on overflow (see `SSHTransport`). `async` so actor conformers satisfy
    /// it without crossing isolation.
    var output: AsyncStream<Data> { get async }

    func send(_ bytes: Data) async throws(SSHTransportError)
    func resize(cols: Int, rows: Int) async
    func close() async

    /// Session child channel of the FINAL hop (T8 agent forwarding attaches
    /// there; NIO types stay module-internal).
    func sessionChannelHandle() async throws(SSHTransportError) -> SSHChannelHandle
}

extension SSHTransport: SSHSessionTransport {}
