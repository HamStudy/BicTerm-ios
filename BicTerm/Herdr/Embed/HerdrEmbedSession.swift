import Foundation
import HerdrEmbed

/// Startup parameters for one embedded herdr client run.
struct HerdrEmbedSessionConfig: Sendable {
    /// herdr server client socket (UDS) the embedded client connects to.
    var socketPath: String
    /// Initial pty window; SwiftTerm's first layout resize corrects it.
    var cols: Int
    var rows: Int
    /// Raw detach key sequence; nil selects herdr's stock ctrl+b q.
    var detachInput: Data? = nil
}

/// Error surfaced by the embed C ABI, with its structured detail.
struct HerdrEmbedError: Error, CustomStringConvertible {
    let code: Int32
    let detail: String

    var description: String { "herdr embed error \(code): \(detail)" }
}

/// The Swift↔embed seam (T4 test surface): everything the hosting stack
/// needs from the embedded client. The production conformer wraps the
/// HerdrEmbed C ABI — the ONLY Swift↔herdr contract; no Swift code may
/// reach past `HerdrEmbed.h`. Tests inject a stub conformer.
protocol HerdrEmbedSession: AnyObject, Sendable {
    /// Read-loop delivery (client output chunks; arbitrary thread).
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    /// Client thread finished; detail is nil for a clean drain.
    var onExit: (@Sendable (_ detail: String?) -> Void)? { get set }

    /// Boots the client; throws `HerdrEmbedError` on failure.
    func start(config: HerdrEmbedSessionConfig) throws
    /// Queues input bytes toward the pty master (drops after stop). Safe
    /// from any thread — the runtime's read-thread output pipeline writes
    /// capability-query answers without a main-actor hop.
    func writeInput(_ data: Data)
    /// Applies TIOCSWINSZ + SIGWINCH (embed crate contract). Safe from any
    /// thread (same serialization as ``writeInput(_:)``).
    func setWinsize(cols: Int, rows: Int)
    var isRunning: Bool { get }
    /// Graceful stop: detach input/SIGTERM, join, restore stdio. Blocks up
    /// to the crate's ~18s budget — never call on the main thread.
    func stopBlocking()
}

/// Production `HerdrEmbedSession` over the C ABI.
///
/// Threading contract (crate docs, "the honest list"): read_output may block
/// for the instance's lifetime and MUST coexist with UI-thread writes, so
/// the read loop owns a dedicated thread; write/winsize/stop serialize on
/// one control queue so nothing races `herdr_embed_stop` (a blocked read is
/// the crate's designed exception — its wake pipe unblocks it during stop).
final class HerdrEmbedClient: HerdrEmbedSession, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (_ detail: String?) -> Void)?

    /// `herdr_embed` opaque handle; set by start, consumed by stop.
    private var handle: UnsafeMutablePointer<herdr_embed>?
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "com.bicterm.herdr.embed.control")
    private let readExited = DispatchSemaphore(value: 0)
    private var readThread: Thread?
    private var stopped = false

    private static let readBufferSize = 64 * 1024

    func start(config: HerdrEmbedSessionConfig) throws {
        precondition(config.cols > 0 && config.rows > 0, "embed cols/rows must be positive")

        let socket = config.socketPath.utf8CString
        var detach = config.detachInput ?? Data()
        var abiConfig = herdr_embed_config()
        var error = HerdrEmbedResult(code: -1, detail: nil)

        let started: UnsafeMutablePointer<herdr_embed>? = socket.withUnsafeBufferPointer { socketBytes in
            detach.withUnsafeMutableBytes { detachBytes in
                abiConfig.socket_path = socketBytes.baseAddress
                abiConfig.cols = UInt16(clamping: config.cols)
                abiConfig.rows = UInt16(clamping: config.rows)
                abiConfig.detach_input = UnsafePointer(detachBytes.baseAddress?.assumingMemoryBound(to: UInt8.self))
                abiConfig.detach_len = detachBytes.count
                return herdr_embed_start(&abiConfig, &error)
            }
        }
        guard let started else {
            throw HerdrEmbedError(code: error.code, detail: Self.detail(of: error))
        }

        lock.lock()
        defer { lock.unlock() }
        handle = started
        stopped = false

        // HerdrEmbed.h: the handle is safe for concurrent read/write/winsize,
        // but not Sendable — box it for the reader thread only.
        let box = HandleBox(started)
        let thread = Thread { [weak self] in
            self?.readLoop(box)
        }
        thread.name = "herdr-embed-read"
        thread.start()
        readThread = thread
    }

    func writeInput(_ data: Data) {
        guard !data.isEmpty else { return }
        controlQueue.async { [weak self] in
            guard let self, let handle = self.currentHandle, !self.stoppedFlag else { return }
            var bytes = data
            bytes.withUnsafeMutableBytes { buffer in
                _ = herdr_embed_write_input(
                    handle,
                    buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    buffer.count
                )
            }
        }
    }

    func setWinsize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        controlQueue.async { [weak self] in
            guard let self, let handle = self.currentHandle, !self.stoppedFlag else { return }
            _ = herdr_embed_set_winsize(handle, UInt16(clamping: cols), UInt16(clamping: rows))
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return herdr_embed_is_running(handle)
    }

    func stopBlocking() {
        controlQueue.sync {
            lock.lock()
            let current = handle
            handle = nil
            stopped = true
            lock.unlock()
            guard let current else { return }
            let result = herdr_embed_stop(current)
            if result.code != HERDR_EMBED_CODE_OK {
                // STOP_TIMEOUT leaves the handle alive per the ABI; surface
                // the failure but keep the local teardown moving (the read
                // loop observed the client thread end either way).
                NSLog("herdr_embed_stop failed: \(Self.detail(of: result))")
            }
        }
        // The reader drains to EOF when stop closes the master; give the
        // loop a moment to unwind so callbacks complete before we return.
        _ = readExited.wait(timeout: .now() + 2)
    }

    // MARK: - Internals

    private var currentHandle: UnsafeMutablePointer<herdr_embed>? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    private var stoppedFlag: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func readLoop(_ box: HandleBox) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readBufferSize, alignment: 64)
        defer { buffer.deallocate() }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        while true {
            var error = HerdrEmbedResult(code: -1, detail: nil)
            let count = herdr_embed_read_output(box.pointer, bytes, Self.readBufferSize, &error)
            if count < 0 {
                onExit?(HerdrEmbedError(code: error.code, detail: Self.detail(of: error)).description)
                break
            }
            if count == 0 {
                onExit?(nil)
                break
            }
            onOutput?(Data(bytes: bytes, count: Int(count)))
        }
        readExited.signal()
    }

    private static func detail(of result: HerdrEmbedResult) -> String {
        guard let pointer = result.detail else { return "<no detail>" }
        return String(cString: pointer)
    }
}

/// `herdr_embed*` crossing into the reader thread: the ABI documents the
/// handle as safe for concurrent read/write/winsize, but Swift imports the
/// pointee as non-Sendable.
private final class HandleBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<herdr_embed>
    init(_ pointer: UnsafeMutablePointer<herdr_embed>) { self.pointer = pointer }
}
