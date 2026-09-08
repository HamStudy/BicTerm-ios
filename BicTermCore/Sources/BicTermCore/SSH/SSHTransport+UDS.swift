import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Unix-domain-socket dialing for Coder workspace sessions.
///
/// Ownership contract: the bridge that fronts a coder session owns the socket
/// PATH (per-session random, 0600, stale-swept, removed at close — see
/// Docs/SECURITY.md); this transport only ever DIALS it. Both entry points
/// share the TCP path's session-establish tail via `openSessionAndActivate`,
/// so handshake, channel-open, PTY and shell semantics cannot drift.
extension SSHTransport {
    /// Dials a unix domain socket instead of TCP, authenticating per the
    /// connection's declared method against the connection's host-key
    /// identity. Conformance surface for the Coder per-session bridge (the
    /// fixture uds-forward.py fronts the regular key-auth sshd this way).
    public func connect(
        unixSocketPath path: String,
        to connection: Connection,
        cols: Int,
        rows: Int
    ) async throws(SSHTransportError) {
        guard cols > 0, rows > 0 else { throw .channelDenied }
        await tearDown()
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
    }

    /// Coder workspace dial (spec §11.2): NoClientAuth — the client offers the
    /// RFC 4252 `none` method under the fixed `coder` username (an example
    /// username per §11.4, never a privilege instruction). Pair with
    /// ``HostKeyVerifier/coderTunnel()``: the tailnet-authorized transport is
    /// the boundary, so the agent's host key is accepted unconditionally.
    public func connect(unixSocketPath path: String, cols: Int, rows: Int) async throws(SSHTransportError) {
        guard cols > 0, rows > 0 else { throw .channelDenied }
        await tearDown()

        // Host/port identity is inert under coderTunnelTrust; port 0 marks
        // the non-TCP boundary in case a TOFU verifier is miswired in.
        let serverAuth = VerifyingHostKeyDelegate(host: path, port: 0, verifier: hostKeyVerifier)
        try await openSessionAndActivate(
            SessionSetup(
                cols: cols,
                rows: rows,
                userAuth: NoClientUserAuthenticationDelegate(username: "coder"),
                serverAuth: serverAuth
            )
        ) { bootstrap in
            let address = try SocketAddress(unixDomainSocketPath: path)
            return try await bootstrap.connect(to: address).get()
        }
    }
}
