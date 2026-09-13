import Foundation
import NIOCore
import NIOPosix

/// Typed failure of one ``HerdrEmbedBridgeServer`` bring-up.
public enum HerdrEmbedBridgeError: Error, Equatable, Sendable {
    /// `bind(2)` refused the socket path (length, permissions, filesystem).
    case bindFailed(path: String, reason: String)
    /// A LIVE listener already owns the socket path — never replaced
    /// (uds-forward.py ownership contract: a stale leftover is swept, a
    /// live one is a hard refusal).
    case liveListenerExists(path: String)
    /// The bridge command could not be built (hostile session name/path).
    case invalidCommand(String)
}

/// Observable lifecycle of one ``HerdrEmbedBridgeServer`` run: byte-flow
/// receipts per relay and the teardown receipt (the T5 evidence surface —
/// loud, never silent).
public enum HerdrEmbedBridgeEvent: Sendable, Equatable {
    case listening(socketPath: String)
    case relayOpened
    /// One local connection finished; `clean` means it ended without a
    /// carrier-level error.
    case relayEnded(clean: Bool, bytesUp: Int, bytesDown: Int)
    /// The SSH carrier refused an exec open or a relay failed at the
    /// connection level — the embed session cannot recover it in place.
    case carrierLost(reason: String)
    /// Stop receipt: listener closed, every live relay torn down, socket
    /// path unlinked when it was still ours.
    case stopped(unlinked: Bool, relaysTornDown: Int)

    /// True for the stop receipt (NIO's listener close may unlink the
    /// socket file before `stop()`'s own sweep, so `unlinked` is
    /// informational — the durable guarantee is the absent file).
    public var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }
}

/// Serves the host side of herdr's `bicterm-transport` seam (plan
/// herdr-embed T5): binds ONE unix-domain-socket listener at
/// `{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock` and relays every
/// accepted connection to a FRESH `remote-client-bridge` exec channel
/// opened on the established carrier — the byte path
/// ``HerdrSSHTransport`` gives the native workspace, but per-connection on
/// ONE long-lived SSH connection, so the embedded client's supervisor
/// reconnects (new local connect → new exec channel) without re-running
/// the TOFU/auth establish.
///
/// Relay shape mirrors `Fixtures/bin/uds-forward.py` (the fixture
/// precedent) natively: full-duplex, half-close on EOF, both directions
/// BOUNDED —
/// - client→remote: the inbound sequence is demand-driven (NIO watermark
///   strategy) and ``SSHExecSession/write(_:)`` suspends on the SSH flow
///   window, so a slow remote back-pressures the local client through the
///   unread socket buffer;
/// - remote→client: ``SSHExecSession/stdout`` is pull-based (bounded
///   `ExecChannelCore` buffers + the SSH receive window) and the NIO
///   outbound writer suspends while the socket is unwritable.
/// No direction stalls silently: terminal states cascade (client EOF →
/// SSH EOF; remote EOF → local channel close; carrier death → both) and
/// surface as typed events.
///
/// The socket path may be RELATIVE: `sockaddr_un.sun_path` holds 104 bytes
/// on Darwin and app-container paths exceed that, so the embed runtime
/// pins the process cwd and passes a short relative transport dir in
/// `HERDR_EMBED_TRANSPORT_DIR` — this listener and the in-process client
/// then resolve the same relative path against that cwd.
public actor HerdrEmbedBridgeServer {
    private let socketPath: String
    private let carrier: any SSHExecCapableConnection
    private let command: String
    private let commandIsInvalid: Bool

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var listener: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>?
    private var acceptTask: Task<Void, Never>?
    private var liveRelayChannels: [ObjectIdentifier: NIOAsyncChannel<ByteBuffer, ByteBuffer>] = [:]
    private var didStop = false

    /// Event sink; set BEFORE ``start()``. Invoked from arbitrary
    /// executors — hop to the caller's context.
    public var onEvent: @Sendable (HerdrEmbedBridgeEvent) -> Void = { _ in }

    public func setOnEvent(_ handler: @escaping @Sendable (HerdrEmbedBridgeEvent) -> Void) {
        onEvent = handler
    }

    public init(
        socketPath: String,
        carrier: any SSHExecCapableConnection,
        executablePath: String,
        sessionName: String? = nil
    ) {
        self.socketPath = socketPath
        self.carrier = carrier
        // BuildError is unreachable for a probe-verified path plus a
        // grammar-checked session name; keep the failure observable
        // instead of trapping in an actor init.
        let built = try? HerdrCommandBuilder.bridgeCommand(
            executablePath: executablePath,
            sessionName: sessionName
        )
        self.command = built ?? ""
        self.commandIsInvalid = built == nil
    }

    public func start() async throws(HerdrEmbedBridgeError) {
        guard !commandIsInvalid else {
            throw .invalidCommand("bridge command rejected (path or session name)")
        }
        guard !didStop, listener == nil else { return }

        try Self.sweepStaleSocket(at: socketPath)
        let parent = (socketPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
        }

        let bound: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            bound = try await ServerBootstrap(group: group)
                .bind(
                    unixDomainSocketPath: socketPath,
                    childChannelInitializer: { child in
                        child.eventLoop.makeCompletedFuture {
                            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: child
                            )
                        }
                    }
                )
        } catch {
            throw .bindFailed(path: socketPath, reason: "\(error)")
        }
        listener = bound
        // uds-forward.py's 0600 contract, applied post-bind: NIO cannot
        // umask its bind, and the app container is private anyway, so this
        // is defense in depth, not the primary boundary.
        chmod(socketPath, 0o600)
        onEvent(.listening(socketPath: socketPath))

        acceptTask = Task { [weak self] in
            await self?.runAcceptLoop(on: bound)
        }
    }

    /// Idempotent teardown with receipts: stops accepting, closes every
    /// live relay's local channel (so inbound iterators wake from a real
    /// EOF instead of dangling), closes the carrier, and unlinks the
    /// socket path when it still exists.
    public func stop() async {
        guard !didStop else { return }
        didStop = true

        acceptTask?.cancel()
        acceptTask = nil
        if let listener {
            listener.channel.close(promise: nil)
            self.listener = nil
        }
        let liveRelays = Array(liveRelayChannels.values)
        liveRelayChannels.removeAll()
        for relay in liveRelays {
            relay.channel.close(promise: nil)
        }

        await carrier.close()

        let unlinked = Self.unlinkIfPresent(socketPath)
        onEvent(.stopped(unlinked: unlinked, relaysTornDown: liveRelays.count))
        try? await group.shutdownGracefully()
    }

    // MARK: - Accept loop

    private func runAcceptLoop(
        on listener: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    ) async {
        do {
            for try await child in listener.inbound {
                guard !didStop else { break }
                startRelay(child)
            }
        } catch is CancellationError {
            // stop() cancelled the accept task — expected teardown path.
        } catch {
            if !didStop {
                onEvent(.carrierLost(reason: "bridge listener ended: \(error)"))
            }
        }
    }

    // MARK: - Relay

    private func startRelay(_ child: NIOAsyncChannel<ByteBuffer, ByteBuffer>) {
        liveRelayChannels[ObjectIdentifier(child.channel)] = child
        Task { [weak self] in
            await self?.runRelay(child)
        }
    }

    private func runRelay(_ child: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        let session: SSHExecSession
        do {
            session = try await carrier.openExecChannel(command: command)
        } catch {
            child.channel.close(promise: nil)
            endRelay(child)
            if !didStop {
                onEvent(.carrierLost(reason: "\(error)"))
            }
            return
        }
        // stop() may have run while the exec channel was opening; nothing
        // else would tear this fresh session down.
        if didStop {
            await session.close()
            child.channel.close(promise: nil)
            endRelay(child)
            return
        }
        onEvent(.relayOpened)

        enum RelayBytes {
            case up(Int)
            case down(Int)
        }

        var clean = true
        let totals: (up: Int, down: Int)
        do {
            totals = try await child.executeThenClose { inbound, outbound -> (up: Int, down: Int) in
                try await withThrowingTaskGroup(of: RelayBytes.self) { group in
                    group.addTask {
                        var written = 0
                        do {
                            for try await chunk in inbound {
                                written += chunk.readableBytes
                                try await session.write(Data(chunk.readableBytesView))
                            }
                            // Client half-close → SSH EOF; the remote reply
                            // stream keeps flowing until it ends on its own.
                            try? await session.closeWrite()
                        } catch {
                            // Wake the sibling direction before throwing:
                            // the group waits on it at scope exit.
                            await session.close()
                            child.channel.close(promise: nil)
                            throw error
                        }
                        return .up(written)
                    }
                    group.addTask {
                        var written = 0
                        do {
                            for try await chunk in session.stdout {
                                written += chunk.count
                                var buffer = child.channel.allocator.buffer(
                                    capacity: chunk.count
                                )
                                buffer.writeBytes(chunk)
                                try await outbound.write(buffer)
                            }
                        } catch {
                            // The LOCAL side went away mid-stream (client
                            // closed after its supervisor decided to
                            // disconnect): a lifecycle end, not a carrier
                            // loss — keep the counted bytes.
                        }
                        // Either terminal state closes the local channel
                        // so the peer and the sibling up-direction see it.
                        child.channel.close(promise: nil)
                        await session.close()
                        return .down(written)
                    }
                    var bytesUp = 0
                    var bytesDown = 0
                    while let relayBytes = try await group.next() {
                        switch relayBytes {
                        case .up(let bytes): bytesUp += bytes
                        case .down(let bytes): bytesDown += bytes
                        }
                    }
                    return (bytesUp, bytesDown)
                }
            }
        } catch is CancellationError {
            clean = false
            totals = (0, 0)
        } catch {
            clean = false
            if !didStop {
                onEvent(.carrierLost(reason: "\(error)"))
            }
            child.channel.close(promise: nil)
            totals = (0, 0)
        }

        await session.close()
        onEvent(.relayEnded(clean: clean, bytesUp: totals.up, bytesDown: totals.down))
        endRelay(child)
    }

    private func endRelay(_ child: NIOAsyncChannel<ByteBuffer, ByteBuffer>) {
        liveRelayChannels.removeValue(forKey: ObjectIdentifier(child.channel))
    }

    // MARK: - Socket path hygiene (uds-forward.py contract)

    /// Unlinks a leftover socket path unless a live listener still owns it.
    private static func sweepStaleSocket(at path: String) throws(HerdrEmbedBridgeError) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if liveListenerOwns(path: path) {
            throw .liveListenerExists(path: path)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Probes the path with a real `connect(2)`: success means some live
    /// listener still answers on it.
    private static func liveListenerOwns(path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    fd,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        return connected == 0
    }

    private static func unlinkIfPresent(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
