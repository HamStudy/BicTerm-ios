import Foundation

/// Default ``SessionTransportFactory``: every `makeTransport()` builds a
/// FRESH T7 `SSHTransport` (new TCP connection, handshake, and auth per
/// reconnect attempt) and wraps it in the Sessions-level seam.
///
/// T9 owns a separate `SSHSessionTransport` protocol under `SSH/Jump/`;
/// this adapter type is deliberately named differently. T11 unifies the
/// two seams — keep this file self-contained.
public struct SSHSessionTransportFactory: SessionTransportFactory {
    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider()
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
    }

    public func makeTransport() -> any SessionTransport {
        SSHSessionTransportAdapter(transport: SSHTransport(
            hostKeyVerifier: hostKeyVerifier,
            authenticationKeyProvider: authenticationKeyProvider
        ))
    }
}

/// Adapts T7's `SSHTransport` to ``SessionTransport``, mapping
/// `SSHTransportError` onto the protocol-agnostic ``SessionTransportError``.
actor SSHSessionTransportAdapter: SessionTransport {
    private let transport: SSHTransport

    init(transport: SSHTransport) {
        self.transport = transport
    }

    var output: AsyncStream<Data> {
        get async {
            await transport.output
        }
    }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(SessionTransportError) {
        do {
            try await transport.connect(to: connection, cols: cols, rows: rows)
        } catch let error {
            throw SessionTransportError(error)
        }
    }

    func send(_ bytes: Data) async throws(SessionTransportError) {
        do {
            try await transport.send(bytes)
        } catch let error {
            throw SessionTransportError(error)
        }
    }

    func resize(cols: Int, rows: Int) async {
        await transport.resize(cols: cols, rows: rows)
    }

    func close() async {
        await transport.close()
    }
}
