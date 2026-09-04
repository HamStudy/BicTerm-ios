import Foundation

/// Builds an ``SSHSessionTransport`` for a `Connection`, transparently
/// chaining ≤5 jump hosts via nested SSH-over-direct-tcpip handshakes.
///
/// Hop indexing in ``JumpError`` is 1-BASED over `[jumpChain..., destination]`.
/// On failure every already-established hop is closed in reverse order before
/// the error is thrown — no partially-open chain leaks.
public struct JumpChainBuilder: Sendable {
    public static let maximumHops = Connection.maximumJumpChainLength

    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let dialer: any JumpDialer

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider()
    ) {
        self.init(
            hostKeyVerifier: hostKeyVerifier,
            authenticationKeyProvider: authenticationKeyProvider,
            dialer: NIOJumpDialer(
                hostKeyVerifier: hostKeyVerifier,
                authenticationKeyProvider: authenticationKeyProvider
            )
        )
    }

    init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider,
        dialer: any JumpDialer
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.dialer = dialer
    }

    /// Throws ONLY ``JumpError`` — declared as untyped `throws` because
    /// `async throws(JumpError)` returning a protocol existential crashes
    /// the Swift 6.2 SIL verifier (LinearLifetimeChecker).
    public func build(
        connection: Connection,
        cols: Int,
        rows: Int
    ) async throws -> any SSHSessionTransport {
        let destination = JumpHopEndpoint(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            keyReference: connection.keyReference
        )
        let jumps = connection.jumpChain.map(JumpHopEndpoint.init(hop:))
        try Self.validate(jumps: jumps, destination: destination)

        guard !jumps.isEmpty else {
            return try await buildDirect(connection: connection, destination: destination, cols: cols, rows: rows)
        }
        return try await buildChained(endpoints: jumps + [destination], cols: cols, rows: rows)
    }

    /// Chains handshakes over `[jumpChain..., destination]`. Kept in a
    /// separate concrete-returning helper with inline reverse-order cleanup:
    /// loops reassigning protocol existentials and error-returning cleanup
    /// helpers inside the public `build` both crash the Swift 6.2 SIL
    /// verifier (LinearLifetimeChecker) during SILGen cleanup.
    private func buildChained(
        endpoints: [JumpHopEndpoint],
        cols: Int,
        rows: Int
    ) async throws -> JumpTransport {
        var established: [any JumpHopConnection] = []

        let first = endpoints[0]
        do {
            established.append(try await dialer.connectTCP(to: first))
        } catch let error as SSHTransportError {
            throw JumpError.hopFailed(hopIndex: 1, host: first.host, port: first.port, underlying: error)
        }

        for index in 1..<endpoints.count {
            let target = endpoints[index]
            let owner = established[index - 1]
            let link: any JumpRawLink
            do {
                link = try await owner.openForward(toHost: target.host, port: target.port)
            } catch let error as SSHTransportError {
                let failingIndex = Self.attributedHopIndex(
                    forwardError: error,
                    ownerIndex: index,
                    targetIndex: index + 1
                )
                let failing = endpoints[failingIndex - 1]
                for hop in established.reversed() {
                    await hop.close()
                }
                throw JumpError.hopFailed(
                    hopIndex: failingIndex,
                    host: failing.host,
                    port: failing.port,
                    underlying: error
                )
            }
            do {
                established.append(try await dialer.connectNested(over: link, to: target))
            } catch let error as SSHTransportError {
                await link.close()
                for hop in established.reversed() {
                    await hop.close()
                }
                throw JumpError.hopFailed(
                    hopIndex: index + 1,
                    host: target.host,
                    port: target.port,
                    underlying: error
                )
            }
        }

        let lastIndex = endpoints.count - 1
        let destination = endpoints[lastIndex]
        let session: any JumpSession
        do {
            session = try await established[lastIndex].openSession(cols: cols, rows: rows)
        } catch let error as SSHTransportError {
            for hop in established.reversed() {
                await hop.close()
            }
            throw JumpError.hopFailed(
                hopIndex: endpoints.count,
                host: destination.host,
                port: destination.port,
                underlying: error
            )
        }
        return JumpTransport(session: session, hops: established)
    }

    // MARK: - Validation

    /// Hard bound + cycle check over the jump chain AND the destination,
    /// keyed on (lowercased host, port). Runs before any network I/O.
    static func validate(
        jumps: [JumpHopEndpoint],
        destination: JumpHopEndpoint
    ) throws {
        guard jumps.count <= maximumHops else {
            throw JumpError.tooManyHops(maximum: maximumHops, actual: jumps.count)
        }
        var seen: Set<String> = []
        for endpoint in jumps + [destination] {
            let key = "\(endpoint.host.trimmingCharacters(in: .whitespaces).lowercased()):\(endpoint.port)"
            guard seen.insert(key).inserted else {
                throw JumpError.cycleDetected(host: endpoint.host, port: endpoint.port)
            }
        }
    }

    /// A handshake-class error (host-key/auth) surfacing from an openForward
    /// belongs to the hop that OWNS the connection — its handshake was queued
    /// until the first channel open and just died. A refusal/eof without a
    /// recorded typed cause belongs to the TARGET (the path to it failed).
    static func attributedHopIndex(
        forwardError error: SSHTransportError,
        ownerIndex: Int,
        targetIndex: Int
    ) -> Int {
        switch error {
        case .requiresTrust, .hostKeyChanged, .authenticationFailed:
            ownerIndex
        case .unreachable, .channelDenied:
            targetIndex
        }
    }

    // MARK: - Direct path

    private func buildDirect(
        connection: Connection,
        destination: JumpHopEndpoint,
        cols: Int,
        rows: Int
    ) async throws(JumpError) -> any SSHSessionTransport {
        let transport = SSHTransport(
            hostKeyVerifier: hostKeyVerifier,
            authenticationKeyProvider: authenticationKeyProvider
        )
        do {
            try await transport.connect(to: connection, cols: cols, rows: rows)
        } catch let error as SSHTransportError {
            throw JumpError.hopFailed(
                hopIndex: 1,
                host: destination.host,
                port: destination.port,
                underlying: error
            )
        }
        return transport
    }
}
