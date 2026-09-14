import BicTermCore
import Foundation
import Observation

/// App-level lifecycle for the embedded herdr TUI client (plan herdr-embed
/// T4). v1 contract: **one embedded TUI per process** — the embed shim's
/// dup2 makes the pty slave the process-wide stdio, so this runtime refuses
/// a second start while one run is alive; herds ride the client's own
/// machine catalog (T6).
///
/// The runtime also answers the client's one capability query SwiftTerm
/// does not: `CSI ? 996 n` (color scheme) → `CSI ? 997 ; 1 n` (dark) or
/// `CSI ? 997 ; 2 n` (light). Cell size (`CSI 16 t`), OSC 10/11, and the
/// OSC 4 palette are answered natively by SwiftTerm's emulator through the
/// hosting view's input path.
@MainActor
@Observable
final class HerdrEmbedRuntime {
    static let shared = HerdrEmbedRuntime()

    enum Phase: Equatable {
        case idle
        case starting
        case running
        /// The client finished (detach keys, server loss, or stop); exit
        /// detail is nil for a clean drain.
        case stopped(exit: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var bytesWritten: Int = 0
    private(set) var socketPath: String?
    /// True while a drop-triggered resync is pending or in flight (the
    /// T12 sync-honesty signal for the embed surface: the VT stream was
    /// cut, a full redraw was requested).
    private(set) var syncSuspect = false
    /// Typed explanation for a failed transport bring-up (T5): kind +
    /// detail mirror the native workspace's diagnostic taxonomy.
    private(set) var failureDiagnostic: HerdrDiagnostic?
    /// Bridge byte-flow/lifecycle lines from the transport coordinator.
    private(set) var transportLines: [String] = []
    /// Identity (workspace-entry id) that owns the live run. Opening a
    /// second workspace while one runs REPLACES the run (v1: one embedded
    /// TUI per process); superseded surfaces render a closed state.
    private(set) var currentOwner: UUID?

    /// Output chunks toward the hosting view; one stream per run, BOUNDED
    /// (``OutputPipeline/bufferChunkLimit`` newest chunks) so a slow view
    /// consumer can never accumulate unbounded memory — drops are counted
    /// loudly and trigger an automatic resync instead of garbling silently.
    private var outputStream: AsyncStream<Data>?

    private var session: HerdrEmbedSession?
    private let sessionFactory: @Sendable () -> HerdrEmbedSession
    /// T5+T6 transport, split in two: the run's ACTIVE coordinator (torn
    /// down with it) and the coordinator STAGED by the next view's task.
    /// The split matters at takeover — the staged coordinator must not be
    /// torn down in place of the live run's.
    private var activeTransport: HerdrEmbedTransportCoordinator?
    private var stagedTransport: HerdrEmbedTransportCoordinator?

    /// Read-thread side of the output path (lock-confined, no MainActor
    /// hops): byte counters, the color-scheme query scanner, the bounded
    /// continuation, and the drop-triggered resync poker.
    private let outputPipeline = OutputPipeline()

    init(sessionFactory: @escaping @Sendable () -> HerdrEmbedSession = { HerdrEmbedClient() }) {
        self.sessionFactory = sessionFactory
    }

    // MARK: - Lifecycle

    /// Stages a transport for the NEXT start (T5 Mode A / T6 herd). A
    /// staged coordinator is inert until that start consumes it; the
    /// ACTIVE run's coordinator is torn down with that run, never by a
    /// later stage call.
    func attachTransport(_ coordinator: HerdrEmbedTransportCoordinator) {
        stagedTransport = coordinator
    }

    /// Starts the embedded client if no run is alive; a live run is reused
    /// (single-instance rule) unless the caller owns a DIFFERENT identity —
    /// opening herd B closes herd A's run cleanly first (v1: one embedded
    /// TUI per process). With a transport staged, the SSH bridges are
    /// established first — TOFU prompts, probes, per-machine listeners,
    /// catalog seeding — and the legacy launch-time socket path is ignored.
    /// Initial geometry is a placeholder — the hosting view's first layout
    /// resize delivers SwiftTerm's real grid.
    func startIfNeeded(
        ownerID: UUID? = nil,
        defaultCols: Int = 80,
        defaultRows: Int = 24
    ) async {
        if let ownerID, (phase == .running || phase == .starting), currentOwner != ownerID {
            await requestStop()
        }
        switch phase {
        case .idle, .stopped, .failed:
            break
        case .starting, .running:
            return
        }

        failureDiagnostic = nil
        transportLines = []
        if let staged = stagedTransport {
            stagedTransport = nil
            activeTransport = staged
        }

        let resolvedSocketPath: String
        if let activeTransport {
            do {
                resolvedSocketPath = try await activeTransport.prepare()
                transportLines = activeTransport.eventLines
            } catch let failure as HerdrEmbedTransportFailure {
                presentTransportFailure(failure)
                await teardownTransport()
                return
            } catch {
                presentTransportFailure(.bridge(
                    .bindFailed(path: "transport", reason: "\(error)")
                ))
                await teardownTransport()
                return
            }
        } else if let legacy = Self.resolveSocketPath() {
            resolvedSocketPath = legacy
        } else {
            phase = .failed(
                "No herdr transport configured. Connect a Herdr-enabled"
                    + " connection (Mode A), open a herd, or launch with"
                    + " -herdr-embed-socket <path> / HERDR_EMBED_SOCKET_PATH"
                    + " for the fixture harness."
            )
            return
        }
        self.socketPath = resolvedSocketPath

        phase = .starting
        currentOwner = ownerID
        let session = sessionFactory()
        prepareClientEnvironment()

        let config = HerdrEmbedSessionConfig(
            socketPath: resolvedSocketPath,
            cols: defaultCols,
            rows: defaultRows
        )
        session.onOutput = { [outputPipeline] chunk in
            outputPipeline.ingest(chunk)
        }
        session.onExit = { [weak self] detail in
            Task { @MainActor [weak self] in
                self?.handleExit(detail)
            }
        }

        let stream = AsyncStream(
            Data.self,
            bufferingPolicy: .bufferingNewest(OutputPipeline.bufferChunkLimit)
        ) { continuation in
            self.outputPipeline.attach(continuation)
        }
        outputStream = stream
        self.session = session
        outputPipeline.bind(
            sendInput: { [weak session] data in session?.writeInput(data) },
            onSuspectChanged: { [weak self] suspect in
                Task { @MainActor [weak self] in
                    self?.syncSuspect = suspect
                }
            }
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try session.start(config: config)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            phase = .running
        } catch {
            phase = .failed("\(error)")
            finishStream()
            self.session = nil
        }
    }

    /// Stops the live run (window/cover closed or Disconnect). Off-main.
    /// An `ownerID` scopes the stop to the run's owning workspace — a
    /// superseded surface closing its window must not kill the run that
    /// replaced it; nil stops unconditionally (the owner's own Disconnect,
    /// tests). The transport (when attached) tears down AFTER the client
    /// joined — its supervisor may still be dialing the bridge socket,
    /// which resolves relative to the cwd the coordinator pinned.
    func requestStop(ownerID: UUID? = nil) async {
        guard phase == .running || phase == .starting else { return }
        if let ownerID, currentOwner != ownerID { return }
        let session = session
        phase = .stopped(exit: nil)
        currentOwner = nil
        finishStream()
        self.session = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session?.stopBlocking()
                continuation.resume()
            }
        }
        await teardownTransport()
    }

    private func handleExit(_ detail: String?) {
        guard session != nil else { return }
        let exitedSession = session
        session = nil
        finishStream()
        currentOwner = nil
        phase = .stopped(exit: detail)
        let transport = activeTransport
        Task { @MainActor in
            // A self-exited client (detach key or loop error) still owes
            // the FFI instance its stop — join, restore process stdio,
            // close the master — otherwise the leaked pty deadlocks the
            // NEXT client's dup2 over stdio (same stop→transport ordering
            // as requestStop; stopBlocking is a fast path once the client
            // thread has ended).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    exitedSession?.stopBlocking()
                    continuation.resume()
                }
            }
            await self.teardownTransport(transport)
        }
    }

    private func teardownTransport(_ explicit: HerdrEmbedTransportCoordinator? = nil) async {
        guard let transport = explicit ?? activeTransport else { return }
        activeTransport = nil
        transportLines = transport.eventLines
        await transport.teardown()
    }

    // MARK: - Transport failure mapping (T5)

    /// Maps a transport bring-up failure onto the run state: trust
    /// declined ends quietly (user cancellation), everything else surfaces
    /// as a typed ``HerdrDiagnostic`` using the native taxonomy's kinds.
    private func presentTransportFailure(_ failure: HerdrEmbedTransportFailure) {
        switch failure {
        case let .connector(error):
            switch error {
            case .trustDeclined:
                phase = .stopped(exit: nil)
                return
            case let .invalidSessionName(name):
                failureDiagnostic = .simple(
                    .transportLost,
                    detail: "The Remote Session name “\(name)” isn’t valid for herdr."
                )
                phase = .failed("The Remote Session name “\(name)” isn’t valid for herdr.")
            case let .incompatibleEndpoint(result, _):
                failureDiagnostic = .incompatibleGeneration(
                    detail: HerdrEndpointConnector.diagnosticDetail(for: result)
                )
                phase = .failed(failureDiagnostic!.detail)
            case let .probeFailed(cause):
                let detail: String
                switch cause {
                case .execChannelFailed:
                    detail = "the herdr probe channel could not open on the host"
                case let .hostileSearchPath(path):
                    detail = "refused an unsafe herdr search path: \(path)"
                }
                failureDiagnostic = .simple(.transportLost, detail: detail)
                phase = .failed(detail)
            case let .sshEstablish(cause), let .bridgeChannelFailed(cause):
                let diagnostic = Self.diagnostic(for: cause)
                failureDiagnostic = diagnostic
                phase = .failed(diagnostic.detail)
            }
        case let .bridge(error):
            let detail = "The herdr bridge could not start: \(error)"
            failureDiagnostic = .simple(.transportLost, detail: detail)
            phase = .failed(detail)
        }
    }

    private static func diagnostic(for cause: SSHTransportError) -> HerdrDiagnostic {
        switch cause {
        case .authenticationFailed, .authRequired:
            .simple(.authLost, detail: cause.localizedDescription)
        default:
            .simple(.transportLost, detail: cause.localizedDescription)
        }
    }

    // MARK: - I/O

    // Gated on the session, not the phase: the client's capability queries
    // and the first layout resize land while the boot await is still in
    // .starting, and their answers must not be dropped.
    func writeInput(_ data: Data) {
        guard let session else { return }
        bytesWritten &+= data.count
        session.writeInput(data)
    }

    func setWinsize(cols: Int, rows: Int) {
        guard let session else { return }
        outputPipeline.noteWinsize(cols: cols, rows: rows)
        session.setWinsize(cols: cols, rows: rows)
    }

    /// Bytes the client produced this run (any thread; monotonic).
    nonisolated var bytesRead: Int { outputPipeline.totalBytesRead }

    /// View-buffer chunks dropped ahead of a slow consumer (any thread;
    /// monotonic). Zero for a lossless run; every increment is announced
    /// by a resync poke, never silently absorbed.
    nonisolated var bytesDropped: Int { outputPipeline.bytesDropped }

    /// The hosting view's current stream (nil outside a run).
    var output: AsyncStream<Data>? { outputStream }

    /// Consumed by the hosting view's feed loop at the top of the next
    /// iteration after a drop episode: the surface performs the local VT
    /// reset, then ``resyncPokeRedraw()`` orders the client's full redraw.
    /// Together this is the T12 resync pair (reset + remote redraw poke)
    /// for the embed surface.
    func takeResyncIfPending() -> Bool {
        outputPipeline.takeResync()
    }

    func resyncPokeRedraw() {
        guard let session, let size = outputPipeline.pendingWinsize else { return }
        session.setWinsize(cols: size.cols, rows: size.rows)
        outputPipeline.announceHandled()
    }

    /// Appearance for the `CSI ? 996 n` answer, from the hosting view's
    /// traits (main thread). Default dark (the app's design tokens are
    /// dark-first).
    func setHostAppearance(dark: Bool) {
        outputPipeline.setAppearance(dark: dark)
    }

    private func finishStream() {
        outputPipeline.finish()
        outputStream = nil
        syncSuspect = false
    }

    // MARK: - Client environment

    /// herdr client env (T3 harness contract): a config that skips the
    /// onboarding overlay (it would swallow input) and a stderr log that
    /// survives teardown. HERDR_CLIENT_SOCKET_PATH is asserted by the embed
    /// crate itself. HOME is left alone — the app container is writable.
    private func prepareClientEnvironment() {
        let support = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = support.appendingPathComponent("client-config.toml")
        try? "onboarding = false\n".write(to: config, atomically: true, encoding: .utf8)
        setenv("HERDR_CONFIG_PATH", config.path(percentEncoded: false), 1)
        setenv(
            "HERDR_EMBED_STDERR_LOG",
            support.appendingPathComponent("client-stderr.log").path,
            1
        )
    }

    // MARK: - Socket resolution (T4: local fixture / explicit config only)

    /// Launch argument `-herdr-embed-socket <path>` beats the
    /// `HERDR_EMBED_SOCKET_PATH` environment; with neither configured the
    /// run fails with instructions. Plan T5 replaces this with transport
    /// injection over BicTermCore SSH.
    nonisolated static func resolveSocketPath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-herdr-embed-socket"),
           flag + 1 < arguments.count {
            return arguments[flag + 1]
        }
        // Live getenv (not ProcessInfo's launch snapshot) so simctl/scheme
        // env injection and test setups are honored.
        if let env = getenv("HERDR_EMBED_SOCKET_PATH"),
           let value = String(validatingUTF8: env), !value.isEmpty {
            return value
        }
        return nil
    }
}

/// Read-thread output path for one embed run (plan herdr-embed T8):
/// everything here is lock-confined and callable from the client's reader
/// thread with NO MainActor hop, so a flood cannot enqueue unbounded
/// main-actor work. The view stream is bounded (`.bufferingNewest`) after
/// the T12 view-buffer shape; a drop is never silent — it is counted and
/// arms a resync that the hosting view's feed loop performs when it
/// resumes: local VT reset (`resetToInitialState`) then a winsize re-apply
/// that SIGWINCHes the client into a full TUI redraw.
private final class OutputPipeline: @unchecked Sendable {
    /// Newest chunks retained while the view consumer lags — matches the
    /// T12 view buffer depth (`SessionSceneModel`'s 256-chunk stream).
    static let bufferChunkLimit = 256

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var totalRead = 0
    private var dropped = 0
    private var queryTail = Data()
    private var appearanceDark = true
    private var lastWinsize: (cols: Int, rows: Int)?
    private var resyncPending = false

    private var sendInput: (@Sendable (Data) -> Void)?
    private var suspectChanged: (@Sendable (Bool) -> Void)?

    func attach(_ continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func bind(
        sendInput: @escaping @Sendable (Data) -> Void,
        onSuspectChanged: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.sendInput = sendInput
        self.suspectChanged = onSuspectChanged
    }

    func setAppearance(dark: Bool) {
        lock.lock()
        defer { lock.unlock() }
        appearanceDark = dark
    }

    func noteWinsize(cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastWinsize = (cols, rows)
    }

    var totalBytesRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalRead
    }

    var bytesDropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    var pendingWinsize: (cols: Int, rows: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return lastWinsize
    }

    func ingest(_ chunk: Data) {
        var response: Data?
        var announceDrop = false
        lock.lock()
        totalRead += chunk.count
        response = colorSchemeResponseLocked(in: chunk)
        if let continuation {
            if case let .dropped(evicted) = continuation.yield(chunk) {
                dropped += evicted.count
                if !resyncPending {
                    resyncPending = true
                    announceDrop = true
                }
            }
        }
        let input = sendInput
        let announce = suspectChanged
        lock.unlock()

        if let response {
            input?(response)
        }
        if announceDrop {
            announce?(true)
        }
    }

    /// One-shot consume for the hosting view's feed loop: true exactly
    /// once per drop episode.
    func takeResync() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = resyncPending
        resyncPending = false
        return pending
    }

    func announceHandled() {
        lock.lock()
        let announce = suspectChanged
        lock.unlock()
        announce?(false)
    }

    func finish() {
        lock.lock()
        resyncPending = false
        continuation?.finish()
        continuation = nil
        sendInput = nil
        suspectChanged = nil
        lock.unlock()
    }

    /// Streaming search for `\x1b[?996n` across chunk boundaries; answers
    /// with the ghostty-documented report `CSI ? 997 ; Ps n` (herdr's
    /// `HostAppearance::color_scheme_report`). Callers hold `lock`.
    private func colorSchemeResponseLocked(in chunk: Data) -> Data? {
        let query: [UInt8] = [0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x36, 0x6e] // ESC [ ? 9 9 6 n
        queryTail.append(chunk)
        if queryTail.count > query.count + 8 {
            queryTail.removeFirst(queryTail.count - (query.count + 8))
        }
        guard queryTail.range(of: Data(query)) != nil else { return nil }
        queryTail.removeAll()
        // Dark: CSI ? 997 ; 1 n — Light: CSI ? 997 ; 2 n
        return appearanceDark
            ? Data([0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x37, 0x3b, 0x31, 0x6e])
            : Data([0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x37, 0x3b, 0x32, 0x6e])
    }
}
