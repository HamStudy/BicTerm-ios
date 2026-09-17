import Darwin
import Foundation
import XCTest

/// Record-only sandbox capability probe — device evidence for replacing the
/// vendored herdr embed client's pty stdio with a socketpair-based design.
///
/// The embed client's first start op opens a pty pair via `libc::openpty`
/// (`Vendor/herdr/herdr-ios-embed/src/pty.rs`); on a physical device the iOS
/// app sandbox denies the underlying device-node opens and the whole start
/// fails with `Operation not permitted (os error 1)`. The simulator does not
/// enforce the app sandbox profile, so simulator-verified runs pass while the
/// device fails. This suite gathers the capability matrix both environments
/// must agree on before the redesign lands.
///
/// RECORD-ONLY: every probe prints one machine-parseable
/// `PROBE: <name> = <result>` line to stdout (captured by xcodebuild's test
/// log) and never fails on an unexpected result — unexpected values ARE the
/// evidence. The only assertions are that each probe executed (recorded its
/// line). Run on a physical device and on the simulator, then diff:
///
///     grep 'PROBE:' <xcodebuild log>
final class SandboxCapabilityProbeTests: XCTestCase {
    /// Probe lines recorded by the running test method — the only thing this
    /// suite asserts (execution, never values).
    private var recorded = 0

    // MARK: - Probes

    /// 1. `openpty` — the exact call the herdr embed client's start makes.
    /// Expected: EPERM on device, success on simulator.
    func testProbeOpenPty() {
        var master: Int32 = -1
        var slave: Int32 = -1
        let rc = openpty(&master, &slave, nil, nil, nil)
        if rc == 0 {
            record("openpty", "ok master=\(master) slave=\(slave)")
            close(master)
            close(slave)
        } else {
            let e = errno
            record("openpty", "fail rc=\(rc) \(errnoText(e))")
        }
        XCTAssertEqual(recorded, 1, "the openpty probe must record exactly one result")
    }

    /// 2. `/dev/ptmx` — the master device node `openpty` opens internally.
    func testProbeOpenPtmx() {
        let fd = open("/dev/ptmx", O_RDWR)
        if fd >= 0 {
            record("open(/dev/ptmx, O_RDWR)", "ok fd=\(fd)")
            close(fd)
        } else {
            let e = errno
            record("open(/dev/ptmx, O_RDWR)", "fail \(errnoText(e))")
        }
        XCTAssertEqual(recorded, 1, "the /dev/ptmx probe must record exactly one result")
    }

    /// 3. `socketpair` + fd operations — the proposed replacement transport.
    /// On success also probes `fcntl(F_SETFL, O_NONBLOCK)`, `dup2` onto a
    /// known-free fd (then releases the alias), and `ioctl(TIOCSWINSZ)`
    /// (expected ENOTTY on a socket — the resize path a socketpair design
    /// must replace with an explicit message).
    func testProbeSocketpairFdOperations() {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        if rc != 0 {
            let e = errno
            record("socketpair(AF_UNIX, SOCK_STREAM)", "fail \(errnoText(e))")
            XCTAssertEqual(recorded, 1, "the socketpair probe must record its result")
            return
        }
        record("socketpair(AF_UNIX, SOCK_STREAM)", "ok fds=[\(fds[0]), \(fds[1])]")

        let fl = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        if fl == 0 {
            record("fcntl(fd, F_SETFL, O_NONBLOCK)", "ok")
        } else {
            let e = errno
            record("fcntl(fd, F_SETFL, O_NONBLOCK)", "fail \(errnoText(e))")
        }

        // Find a known-free fd (dup allocates one, close frees it again),
        // then dup2 onto it and release the alias — restoring the slot.
        let spare = dup(fds[0])
        if spare >= 0 {
            close(spare)
            let d2 = dup2(fds[0], spare)
            if d2 >= 0 {
                record("dup2(fds[0], freeFd)", "ok target=\(d2)")
                close(d2)
            } else {
                let e = errno
                record("dup2(fds[0], freeFd)", "fail \(errnoText(e))")
            }
        } else {
            let e = errno
            record("dup2(fds[0], freeFd)", "skipped: dup failed \(errnoText(e))")
        }

        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let io = ioctl(fds[0], TIOCSWINSZ, &ws)
        if io == 0 {
            record("ioctl(fd, TIOCSWINSZ)", "ok")
        } else {
            let e = errno
            record("ioctl(fd, TIOCSWINSZ)", "fail \(errnoText(e))")
        }

        close(fds[0])
        close(fds[1])
        XCTAssertEqual(recorded, 4, "socketpair and all three fd sub-probes must record")
    }

    /// 4. Path writability — the four container locations via
    /// FileManager.createFile, plus POSIX `open(O_CREAT|O_WRONLY)` companions
    /// for the container home root (captures the errno FileManager hides)
    /// and the real `/tmp` (the herdr embed default transport anchor).
    /// Every file created is removed again.
    func testProbePathWritability() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let token = UUID().uuidString

        let locations: [(label: String, dir: String)] = [
            ("container-home-root", home),
            ("container-tmp", (home as NSString).appendingPathComponent("tmp")),
            ("container-Documents", (home as NSString).appendingPathComponent("Documents")),
            ("container-Library", (home as NSString).appendingPathComponent("Library")),
        ]
        for location in locations {
            let target = (location.dir as NSString)
                .appendingPathComponent("bicterm-probe-\(token)")
            let ok = fm.createFile(atPath: target, contents: Data("probe".utf8))
            record("createFile(\(location.label)/bicterm-probe-<uuid>)", ok ? "ok" : "fail")
            if ok {
                try? fm.removeItem(atPath: target)
            }
        }

        let homeRootFile = (home as NSString)
            .appendingPathComponent("bicterm-probe-\(token)")
        let homeFd = open(homeRootFile, O_CREAT | O_WRONLY, 0o600)
        if homeFd >= 0 {
            record("open(<home>/bicterm-probe-<uuid>, O_CREAT|O_WRONLY)", "ok fd=\(homeFd)")
            close(homeFd)
            unlink(homeRootFile)
        } else {
            let e = errno
            record("open(<home>/bicterm-probe-<uuid>, O_CREAT|O_WRONLY)", "fail \(errnoText(e))")
        }

        let realTmpFile = "/tmp/bicterm-probe-\(token)"
        let tmpFd = open(realTmpFile, O_CREAT | O_WRONLY, 0o600)
        if tmpFd >= 0 {
            record("open(/tmp/bicterm-probe-<uuid>, O_CREAT|O_WRONLY)", "ok fd=\(tmpFd)")
            close(tmpFd)
            unlink(realTmpFile)
        } else {
            let e = errno
            record("open(/tmp/bicterm-probe-<uuid>, O_CREAT|O_WRONLY)", "fail \(errnoText(e))")
        }

        XCTAssertEqual(recorded, 6, "all path-writability probes must record")
    }

    /// 5. Environment — where a `$HOME`-relative fallback would resolve on
    /// each platform (container vs passwd entry).
    func testProbeEnvironment() {
        record("NSHomeDirectory()", NSHomeDirectory())
        let homeEnv = getenv("HOME").map { String(cString: $0) } ?? "(unset)"
        record("getenv(HOME)", homeEnv)
        record("getuid()", "\(getuid())")
        let pwDir: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            pwDir = String(cString: dir)
        } else {
            pwDir = "(no passwd entry / null pw_dir)"
        }
        record("getpwuid(getuid()).pw_dir", pwDir)
        XCTAssertEqual(recorded, 4, "all environment probes must record")
    }

    // MARK: - Helpers

    /// Print one machine-parseable evidence line and count it so the test
    /// can assert the probe executed.
    private func record(_ name: String, _ result: String) {
        print("PROBE: \(name) = \(result)")
        fflush(stdout)
        recorded += 1
    }

    private func errnoText(_ value: Int32) -> String {
        "\(errnoName(value))=\(value) (\(String(cString: strerror(value))))"
    }

    /// `String(describing:)` on `POSIXErrorCode` renders as
    /// "POSIXErrorCode(rawValue: N)" on this SDK, so name the interesting
    /// codes explicitly and fall back to the raw number.
    private func errnoName(_ value: Int32) -> String {
        switch value {
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case EACCES: return "EACCES"
        case EROFS: return "EROFS"
        case ENOTTY: return "ENOTTY"
        case ENOTSUP: return "ENOTSUP"
        case EBADF: return "EBADF"
        case EMFILE: return "EMFILE"
        default: return "errno\(value)"
        }
    }
}
