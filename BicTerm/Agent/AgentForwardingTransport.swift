import BicTermCore
import Foundation

/// Maps a forwarded-agent bridge session ID to the connection that owned the
/// transport, so approval prompts route to the originating scene. Written
/// from the (synchronous) transport factory, so lock-protected rather than
/// an actor.
final class AgentSessionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var connectionBySession: [String: UUID] = [:]

    func record(sessionID: String, connectionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        connectionBySession[sessionID] = connectionID
    }

    func remove(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        connectionBySession[sessionID] = nil
    }

    func connectionID(for sessionID: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return connectionBySession[sessionID]
    }

    func sessionIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connectionBySession.keys)
    }
}

/// Wraps a transport produced by another factory so SSH agent forwarding is
/// installed deterministically BEFORE the underlying connect: `connect` first
/// awaits ``AgentForwardingBridge/install(on:)`` (the NIOSSH child-channel
/// initializer is captured at connect time, so installing first is the T8
/// ordering contract), then delegates.
///
/// Every other operation forwards unchanged; `close` releases the session's
/// entry in the routing book.
final class AgentForwardingTransport: TerminalTransport {
    private let base: any TerminalTransport
    private let sshTransport: SSHTransport?
    private let bridge: AgentForwardingBridge?
    private let bridgeSessionID: String?
    private let book: AgentSessionBook?

    init(
        base: any TerminalTransport,
        sshTransport: SSHTransport?,
        bridge: AgentForwardingBridge?,
        bridgeSessionID: String?,
        book: AgentSessionBook?
    ) {
        self.base = base
        self.sshTransport = sshTransport
        self.bridge = bridge
        self.bridgeSessionID = bridgeSessionID
        self.book = book
    }

    var output: AsyncStream<Data> {
        get async { await base.output }
    }

    var resumeStrategy: ResumeStrategy { base.resumeStrategy }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        if let bridge, let sshTransport {
            await bridge.install(on: sshTransport)
        }
        try await base.connect(to: connection, cols: cols, rows: rows)
    }

    func send(_ bytes: Data) async throws(TransportError) {
        try await base.send(bytes)
    }

    func resize(cols: Int, rows: Int) async {
        await base.resize(cols: cols, rows: rows)
    }

    func suspend() async {
        await base.suspend()
    }

    func resume() async throws(TransportError) {
        try await base.resume()
    }

    func close() async {
        await base.close()
        if let bridgeSessionID, let book {
            book.remove(sessionID: bridgeSessionID)
        }
    }
}

/// ``TerminalTransportFactory`` decorator: fresh transports from `base`
/// carry a forwarded-agent bridge whenever agent forwarding applies (SSH
/// connections with a direct `SSHTransport`; jump-chain transports skip
/// agent forwarding in v1). Each transport instance gets its own bridge
/// session identity recorded in the routing book.
struct AgentForwardingTransportFactory: TerminalTransportFactory {
    let base: any TerminalTransportFactory
    let keyProvider: any AgentKeyProvider
    let authorizer: AgentAuthorizationService
    let book: AgentSessionBook
    let agentForwardingApplies: @Sendable (Connection) -> Bool

    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        let base = try self.base.makeTransport(for: connection)

        guard agentForwardingApplies(connection) else {
            return AgentForwardingTransport(
                base: base, sshTransport: nil, bridge: nil, bridgeSessionID: nil, book: book
            )
        }

        let bridgeSessionID = UUID().uuidString
        book.record(sessionID: bridgeSessionID, connectionID: connection.id)

        // Agent forwarding rides on the direct SSH transport; a jump-chain
        // transport has no exposed agent seam in v1 — pass it through.
        if let ssh = base as? SSHTransport {
            let bridge = AgentForwardingBridge(
                keyProvider: keyProvider,
                authorizer: authorizer,
                sessionID: bridgeSessionID,
                host: connection.host
            )
            return AgentForwardingTransport(
                base: base, sshTransport: ssh, bridge: bridge,
                bridgeSessionID: bridgeSessionID, book: book
            )
        }

        return AgentForwardingTransport(
            base: base, sshTransport: nil, bridge: nil,
            bridgeSessionID: bridgeSessionID, book: book
        )
    }
}
