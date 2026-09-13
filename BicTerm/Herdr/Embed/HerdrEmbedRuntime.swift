#if HERDR_EMBED
import Foundation
import Observation
import os

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
    private(set) var bytesRead: Int = 0
    private(set) var bytesWritten: Int = 0
    private(set) var socketPath: String?

    /// Output chunks toward the hosting view; one stream per run.
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var outputStream: AsyncStream<Data>?

    private var session: HerdrEmbedSession?
    private let sessionFactory: @Sendable () -> HerdrEmbedSession

    /// Streaming scanner state for the color-scheme query (read thread).
    private var queryTail = Data()
    /// Current appearance for the answer; updated from the hosting view's
    /// traits. Default dark (the app's design tokens are dark-first).
    private let appearanceDark = OSAllocatedUnfairLock(initialState: true)

    init(sessionFactory: @escaping @Sendable () -> HerdrEmbedSession = { HerdrEmbedClient() }) {
        self.sessionFactory = sessionFactory
    }

    // MARK: - Lifecycle

    /// Starts the embedded client if no run is alive; a live run is reused
    /// (single-instance rule). Initial geometry is a placeholder — the
    /// hosting view's first layout resize delivers SwiftTerm's real grid.
    func startIfNeeded(defaultCols: Int = 80, defaultRows: Int = 24) async {
        switch phase {
        case .idle, .stopped, .failed:
            break
        case .starting, .running:
            return
        }

        guard let socketPath = Self.resolveSocketPath() else {
            phase = .failed(
                "No herdr server socket configured. Launch with"
                    + " -herdr-embed-socket <path> or set HERDR_EMBED_SOCKET_PATH."
                    + " (Transport injection — plan T5 — replaces this.)"
            )
            return
        }
        self.socketPath = socketPath

        phase = .starting
        let session = sessionFactory()
        prepareClientEnvironment()

        let config = HerdrEmbedSessionConfig(
            socketPath: socketPath,
            cols: defaultCols,
            rows: defaultRows
        )
        session.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.handleOutput(chunk)
            }
        }
        session.onExit = { [weak self] detail in
            Task { @MainActor [weak self] in
                self?.handleExit(detail)
            }
        }

        let stream = AsyncStream<Data> { continuation in
            self.outputContinuation = continuation
        }
        outputStream = stream
        self.session = session

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
    func requestStop() async {
        guard phase == .running || phase == .starting else { return }
        let session = session
        phase = .stopped(exit: nil)
        finishStream()
        self.session = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session?.stopBlocking()
                continuation.resume()
            }
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
        session.setWinsize(cols: cols, rows: rows)
    }

    /// The hosting view's current stream (nil outside a run).
    var output: AsyncStream<Data>? { outputStream }

    /// Appearance for the `CSI ? 996 n` answer, from the hosting view's
    /// traits (main thread).
    func setHostAppearance(dark: Bool) {
        appearanceDark.withLock { $0 = dark }
    }

    // MARK: - Output path

    private func handleOutput(_ chunk: Data) {
        guard session != nil else { return }
        bytesRead &+= chunk.count

        // The color-scheme query is the one herdr probe SwiftTerm cannot
        // answer; the response must not depend on the view being attached.
        if let response = colorSchemeResponse(in: chunk) {
            writeInput(response)
        }
        outputContinuation?.yield(chunk)
    }

    private func handleExit(_ detail: String?) {
        guard session != nil else { return }
        session = nil
        finishStream()
        phase = .stopped(exit: detail)
    }

    private func finishStream() {
        outputContinuation?.finish()
        outputContinuation = nil
        outputStream = nil
    }

    /// Streaming search for `\x1b[?996n` (9 bytes) across chunk boundaries;
    /// answers with the ghostty-documented report `CSI ? 997 ; Ps n`
    /// (herdr's `HostAppearance::color_scheme_report`).
    private func colorSchemeResponse(in chunk: Data) -> Data? {
        let query: [UInt8] = [0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x36, 0x6e] // ESC [ ? 9 9 6 n
        queryTail.append(chunk)
        if queryTail.count > query.count + 8 {
            queryTail.removeFirst(queryTail.count - (query.count + 8))
        }
        guard queryTail.range(of: Data(query)) != nil else { return nil }
        queryTail.removeAll()
        let dark = appearanceDark.withLock { $0 }
        // Dark: CSI ? 997 ; 1 n — Light: CSI ? 997 ; 2 n
        return dark
            ? Data([0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x37, 0x3b, 0x31, 0x6e])
            : Data([0x1b, 0x5b, 0x3f, 0x39, 0x39, 0x37, 0x3b, 0x32, 0x6e])
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
#endif
