import Foundation

/// Process-global cwd pin shared by every embedded-transport bring-up
/// (Mode A host and every herd machine): Darwin `sockaddr_un.sun_path`
/// holds 104 bytes and app-container absolute paths exceed it, so the
/// bridge sockets bind RELATIVE paths (`tmp/herdr-embed-transport/<profile>
/// .sock`) that the kernel resolves against the process cwd — and the
/// in-process Rust client resolves the same relative paths against the
/// same pin. Every bring-up pins the cwd to the app home before binding
/// and releases it at teardown.
///
/// The pin is OWNED. Bring-ups can overlap (a stop for the previous run
/// can still be unwinding while the next run's coordinator has already
/// pinned), and the process cwd is global — so a release by a
/// SUPERSEDED owner must not restore the cwd out from under the newer
/// bring-up's live pin (that un-pin is what turns the relative binds
/// into `bind(2)` ENOENT). Only the CURRENT owner's release restores the
/// pre-pin cwd; a superseded owner's release is a cwd no-op (its bridges
/// and carriers are still torn down by its coordinator).
public enum HerdrEmbedTransportWorkspace {
    /// Typed failure of the pin itself — surfaced instead of proceeding
    /// to relative binds that would fail with a misleading ENOENT.
    public enum PinFailure: Error, Equatable, Sendable {
        case pinFailed(target: String, errno: Int32)
    }

    private static let lock = NSLock()
    /// cwd to restore when the CURRENT owner releases; recorded once, at
    /// the FIRST pin (a newer owner re-pins the same home). Lock-confined.
    nonisolated(unsafe) private static var restorePath: String?
    nonisolated(unsafe) private static var owner: ObjectIdentifier?

    /// Pins the process cwd to `homeDirectory` on behalf of `owner`.
    /// Re-pin by the same or a newer owner is idempotent (the original
    /// restore path is kept); the first pin records the cwd to restore.
    public static func pinCWD(homeDirectory: String, owner: AnyObject) throws(PinFailure) {
        lock.lock()
        defer { lock.unlock() }
        let current = FileManager.default.currentDirectoryPath
        guard chdir(homeDirectory) == 0 else {
            throw .pinFailed(target: homeDirectory, errno: errno)
        }
        if restorePath == nil {
            restorePath = current
        }
        self.owner = ObjectIdentifier(owner)
    }

    /// Releases the pin iff `owner` still holds it: the current owner's
    /// release restores the pre-pin cwd; a superseded owner's release
    /// leaves the newer bring-up's pin (and the cwd) untouched.
    public static func releaseCWD(owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        guard let path = restorePath, Self.owner == ObjectIdentifier(owner) else { return }
        restorePath = nil
        self.owner = nil
        chdir(path)
    }
}
