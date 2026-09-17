import Darwin
import Foundation
import XCTest

@testable import BicTerm

/// Device proof for the socketpair embed redesign: `herdr_embed_start` must
/// boot the real client past the pty stage on a physical device.
///
/// The pty design died at `libc::openpty` — the iOS app sandbox denies the
/// pty device-node opens with EPERM, so every start failed as
/// `herdr embed error 4: start: Operation not permitted (os error 1)`
/// (device probe 2026-09-17, `.sisyphus/evidence/device-probe.log`). The
/// socketpair design replaces the pty with `socketpair(AF_UNIX,
/// SOCK_STREAM)` — legal on the same device — so start must now succeed and
/// the client thread must reach `run_client` (config load, endpoint catalog,
/// server connect, handshake wait).
///
/// This test stands in a herdr server with a silent POSIX UDS listener: the
/// client connects, sends its hello, and waits out the 5s local-handshake
/// timeout, so a successful run looks like: start returns a handle, the
/// client stays running for the handshake window, then exits with the
/// handshake error (captured in the stderr log). RECORD-STYLE: every step
/// prints one machine-parseable `EMBED-BOOT: <name> = <result>` line; the
/// hard assertions are only that start succeeded (never the pty EPERM) and
/// that the client was observed running.
final class HerdrEmbedDeviceBootTests: XCTestCase {
    private var recorded = 0

    func testEmbedClientBootsPastThePtyStage() {
        // Scratch under the container tmp/ (device-writable, probe-proven);
        // the cwd pin makes the socket path relative so sockaddr_un.sun_path
        // (104 bytes) cannot overflow on container-absolute paths — the same
        // pattern the production transport coordinator uses.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed-boot-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            XCTFail("cannot create scratch: \(error)")
            return
        }
        let cwdBefore = FileManager.default.currentDirectoryPath
        defer {
            close(listenerFd)
            let _ = try? FileManager.default.removeItem(at: scratch)
            _ = FileManager.default.changeCurrentDirectoryPath(cwdBefore)
            restoreEnv()
        }
        XCTAssertTrue(
            FileManager.default.changeCurrentDirectoryPath(scratch.path),
            "cwd pin into the scratch dir failed"
        )

        // Production env shape (HerdrEmbedRuntime.prepareClientEnvironment):
        // config, stderr log, and XDG homes inside container-writable dirs.
        setEnvScratch("HERDR_CONFIG_PATH", scratch.appendingPathComponent("client-config.toml").path)
        try? "onboarding = false\n".write(
            to: scratch.appendingPathComponent("client-config.toml"),
            atomically: true,
            encoding: .utf8
        )
        setEnvScratch("HERDR_EMBED_STDERR_LOG", scratch.appendingPathComponent("client-stderr.log").path)
        setEnvScratch("XDG_CONFIG_HOME", scratch.appendingPathComponent("config-home").path)
        setEnvScratch("XDG_STATE_HOME", scratch.appendingPathComponent("state-home").path)

        // Silent listener: binds, never accepts or answers. The client's
        // connect succeeds through the backlog and it waits out the 5s
        // local-handshake read timeout.
        let socketName = "embed-boot.sock"
        guard bindUnixListener(socketName) else {
            record("listener", "bind failed errno=\(errno)")
            XCTFail("could not bind the silent listener")
            return
        }
        record("listener", "ok (silent UDS listener at \(socketName))")

        let evidence = BootEvidence()
        let session = HerdrEmbedClient()
        session.onOutput = { chunk in
            evidence.addOutput(chunk.count)
        }
        session.onExit = { detail in
            evidence.setExit(detail ?? "(clean drain)")
        }

        do {
            try session.start(
                config: HerdrEmbedSessionConfig(
                    socketPath: socketName,
                    cols: 80,
                    rows: 24
                )
            )
            record("start", "ok (socketpair opened, client thread spawned)")
        } catch {
            let detail = (error as? HerdrEmbedError).map { "\($0)" } ?? "\(error)"
            record("start", "FAILED \(detail)")
            // The exact old failure signature: code 4 (IO) wrapping the
            // openpty EPERM. Any throw is a regression, but name the pty
            // stage explicitly when it is the sandbox denial.
            XCTAssertFalse(
                detail.contains("Operation not permitted"),
                "start failed at the pty stage again: \(detail)"
            )
            XCTFail("herdr_embed_start failed: \(detail)")
            return
        }

        var sawRunning = false
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if session.isRunning {
                sawRunning = true
            } else {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        record("running", sawRunning ? "true (client reached run_client)" : "false")
        record("outputBytes", "\(evidence.outputBytes)")
        XCTAssertTrue(
            sawRunning,
            "the client never stayed up after start — it must boot past the pty stage"
        )

        session.stopBlocking()
        record("stop", "completed (exit detail: \(evidence.exitDetail ?? "(none yet)"))")
        record("clientLog", clientLogTail(scratch))

        XCTAssertEqual(recorded, 6, "every boot step must record its result")
        flushRecords()
    }

    // MARK: - Helpers

    private var listenerFd: Int32 = -1
    private var savedEnv: [String: String?] = [:]
    /// Records printed while the client's stdio redirect is active vanish
    /// into the socketpair (the embed read loop counts them as output), so
    /// lines are buffered and flushed after stopBlocking restores stdio.
    private var pendingRecords: [(String, String)] = []

    private func record(_ name: String, _ result: String) {
        pendingRecords.append((name, result))
        recorded += 1
    }

    private func flushRecords() {
        for (name, result) in pendingRecords {
            print("EMBED-BOOT: \(name) = \(result)")
        }
        fflush(stdout)
        pendingRecords.removeAll()
    }

    /// Binds a listening AF_UNIX socket at the relative `path` (resolved
    /// against the pinned cwd). Returns true on bind+listen success.
    private func bindUnixListener(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        listenerFd = fd
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
            return false
        }
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout<sockaddr_un>.size - sunPathOffset else {
            return false
        }
        withUnsafeMutableBytes(of: &addr) { rawAddr in
            guard let base = rawAddr.baseAddress?.advanced(by: sunPathOffset) else { return }
            pathBytes.withUnsafeBytes { rawPath in
                rawPath.baseAddress.map { source in
                    memcpy(base, source, pathBytes.count)
                }
            }
        }
        let bindRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRc == 0 else { return false }
        return listen(fd, 16) == 0
    }

    private func setEnvScratch(_ name: String, _ value: String) {
        savedEnv[name] = getenv(name).map { String(cString: $0) }
        setenv(name, value, 1)
    }

    private func restoreEnv() {
        for (name, value) in savedEnv {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        savedEnv.removeAll()
    }

    /// Tail of the client's rotating log under the scratch XDG homes — the
    /// boot evidence ("connecting to server", the handshake timeout).
    private func clientLogTail(_ scratch: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: scratch,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        let logs = files
            .filter { $0.hasDirectoryPath }
            .flatMap { dir in
                (try? FileManager.default.subpathsOfDirectory(atPath: dir.path))?
                    .filter { $0.hasSuffix(".log") }
                    .map { dir.appendingPathComponent($0) } ?? []
            }
        guard let newest = logs.max(by: { a, b in
            let date = { (url: URL) -> Date in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            return date(a) < date(b)
        }), let text = try? String(contentsOf: newest, encoding: .utf8) else {
            return "(no client log)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(2).joined(separator: " | ")
    }
}

/// Thread-safe collection of the session callbacks (they arrive on the
/// embed read thread).
private final class BootEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var outputByteCount = 0
    private var exitDetailValue: String?

    var outputBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return outputByteCount
    }

    var exitDetail: String? {
        lock.lock()
        defer { lock.unlock() }
        return exitDetailValue
    }

    func addOutput(_ count: Int) {
        lock.lock()
        outputByteCount += count
        lock.unlock()
    }

    func setExit(_ detail: String) {
        lock.lock()
        exitDetailValue = detail
        lock.unlock()
    }
}
