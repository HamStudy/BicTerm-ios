import Foundation

/// Device-diagnostic capture for establish failures the typed-error
/// contract collapses: every point that would otherwise swallow an error
/// into `.channelDenied` (or `.authenticationFailed`) records the FULL
/// underlying error chain here first, rendered with `String(reflecting:)`
/// so the typed chain (CryptoKit / Security / LocalAuthentication / NIO /
/// ChannelError) survives instead of collapsing. Records carry a
/// where-context string only — never key material, passwords, or
/// passphrases.
///
/// Why a process-global sink: the deepest swallow point lives inside
/// `SSHTransport.openSessionAndActivate`, where the pipeline recorder
/// holds an error that is not an `SSHTransportError` and the typed
/// contract has no case to carry it. The device diagnostic
/// (`HerdrEmbedHerdDeviceDiagnosticTests`) clears the buffer before a
/// run and dumps the snapshot after; ordinary runs pay one lock-confined
/// append per swallowed error and nothing else.
public final class SSHEstablishDiagnostics: @unchecked Sendable {
    // @unchecked Sendable: lock-confined ring buffer (same idiom as
    // InboundDropSignal). `shared` is a let constant.
    public static let shared = SSHEstablishDiagnostics()

    private let lock = NSLock()
    private var records: [String] = []
    private let capacity = 128

    private init() {}

    /// Records one swallowed error: `context` names the collapse site.
    public func record(_ context: String, error: Error) {
        append("\(context): \(String(reflecting: error))")
    }

    /// Records a plain diagnostic line (e.g. a channel death that produced
    /// no errorCaught payload at all).
    public func record(_ line: String) {
        append(line)
    }

    /// Captured lines, oldest first.
    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// Clears the capture so a diagnostic run dumps exactly its own
    /// swallowed errors.
    public func removeAll() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }

    private func append(_ line: String) {
        lock.lock()
        records.append(line)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        lock.unlock()
    }
}
