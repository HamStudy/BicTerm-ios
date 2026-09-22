import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Unix-domain-socket dialing.
///
/// Ownership contract: the forwarder that fronts the socket owns the PATH
/// (per-session random, 0600, stale-swept, removed at close — see
/// Docs/SECURITY.md); this transport only ever DIALS it. The UDS entry point
/// shares the TCP path's session-establish tail via `openSessionAndActivate`,
/// so handshake, channel-open, PTY and shell semantics cannot drift.
extension SSHTransport {
    /// Dials a unix domain socket instead of TCP, authenticating per the
    /// connection's declared method against the connection's host-key
    /// identity. Conformance surface for UDS-fronted SSH endpoints (the
    /// fixture uds-forward.py fronts the regular key-auth sshd this way).
    public func connect(
        unixSocketPath path: String,
        to connection: Connection,
        cols: Int,
        rows: Int
    ) async throws(SSHTransportError) {
        guard cols > 0, rows > 0 else {
            await connectKeyScope?.invalidate()
            throw .channelDenied
        }
        await tearDown()
        do {
            let userAuth = try await userAuthDelegate(for: connection)
            let serverAuth = VerifyingHostKeyDelegate(
                host: connection.host,
                port: connection.port,
                verifier: hostKeyVerifier
            )
            try await openSessionAndActivate(
                SessionSetup(cols: cols, rows: rows, userAuth: userAuth, serverAuth: serverAuth)
            ) { bootstrap in
                let address = try SocketAddress(unixDomainSocketPath: path)
                return try await bootstrap.connect(to: address).get()
            }
        } catch {
            await connectKeyScope?.invalidate()
            throw error
        }
        await connectKeyScope?.invalidate()
    }
}
