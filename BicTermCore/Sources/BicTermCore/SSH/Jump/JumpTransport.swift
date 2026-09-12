import Foundation

/// Session I/O for a jump chain: speaks to the FINAL hop and owns every
/// intermediate hop connection so `close()` tears the whole chain down in
/// reverse order. The terminal/session layer sees only
/// ``SSHSessionTransport``.
public actor JumpTransport: SSHSessionTransport {
    public let output: AsyncStream<Data>
    public var closeReason: TransportCloseReason { session.closeReason }

    private let session: any JumpSession
    private var hops: [any JumpHopConnection]
    private var isClosed = false

    init(session: any JumpSession, hops: [any JumpHopConnection]) {
        self.session = session
        self.output = session.output
        self.hops = hops
    }

    public func send(_ bytes: Data) async throws(SSHTransportError) {
        try await session.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        await session.resize(cols: cols, rows: rows)
    }

    public func sessionChannelHandle() async throws(SSHTransportError) -> SSHChannelHandle {
        try session.sessionChannelHandle()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await session.close()
        for hop in hops.reversed() {
            await hop.close()
        }
        hops = []
    }
}
