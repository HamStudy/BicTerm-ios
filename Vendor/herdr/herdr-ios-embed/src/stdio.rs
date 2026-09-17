//! stdio shim: `socketpair` pair plus fd hygiene helpers (plan task 3,
//! redesigned for physical devices).
//!
//! The pair is deliberately tiny: `host` stays with the embed instance for
//! input/output; `client` is dup2'd onto fds 0/1/2 inside the embed thread
//! so `herdr::run_client`'s crossterm writes its TUI frames where the host
//! reads them. The original design used a pty pair; the iOS app sandbox
//! denies `openpty` with EPERM on physical devices (device probe
//! 2026-09-17, `.sisyphus/evidence/device-probe.log`) while socketpair,
//! fcntl, and dup2 are legal there, so the pair is a plain AF_UNIX stream
//! socketpair. Two consequences ripple through the crate: `isatty` is false
//! on both ends (embed patch 0006 bypasses crossterm raw mode and the tty
//! geometry ioctl in the client), and `ioctl(TIOCSWINSZ)` returns ENOTSUP
//! on sockets — the window size travels as explicit env state
//! ([`set_size_env`]) consumed by the client's 100ms resize poll, not as an
//! ioctl plus SIGWINCH.
use std::io;
use std::os::unix::io::RawFd;
#[cfg(test)]
use std::fs;

pub(crate) struct IoPair {
    pub host: RawFd,
    pub client: RawFd,
}

impl IoPair {
    /// Opens a new socketpair. The host end is non-blocking so a client that
    /// stopped draining surfaces as `WouldBlock` (a typed IO error) instead
    /// of blocking the host's write path; the client end keeps blocking
    /// semantics — the client polls before reading, as it did on the pty
    /// slave.
    pub(crate) fn open() -> io::Result<Self> {
        let mut fds: [RawFd; 2] = [-1, -1];
        // SAFETY: plain socketpair(2) with valid out-parameters; on success
        // both fds are owned by the returned IoPair and closed by its Drop.
        if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) } != 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl F_GETFL/F_SETFL on an fd we own; on failure both
        // half-built fds are closed and the error surfaces.
        let flags = unsafe { libc::fcntl(fds[0], libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(fds[0], libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            let error = io::Error::last_os_error();
            for fd in fds {
                if fd >= 0 {
                    // SAFETY: close(2) cleanup of the half-built pair.
                    let _ = unsafe { libc::close(fd) };
                }
            }
            return Err(error);
        }
        Ok(Self {
            host: fds[0],
            client: fds[1],
        })
    }

    /// Consumes the pair without closing: the host end becomes the
    /// instance's read/write surface, the client end moves to the embed
    /// thread (which closes it after the dup2s). Callers own both fds from
    /// here on.
    pub(crate) fn into_parts(self) -> (RawFd, RawFd) {
        let pair = std::mem::ManuallyDrop::new(self);
        // SAFETY: ManuallyDrop keeps both fds open; the fields are plain
        // ints read once and the original Drop never runs.
        (pair.host, pair.client)
    }
}

impl Drop for IoPair {
    fn drop(&mut self) {
        for fd in [self.host, self.client] {
            if fd >= 0 {
                // SAFETY: plain close(2) on fds this struct owns exactly once.
                let _ = unsafe { libc::close(fd) };
            }
        }
        self.host = -1;
        self.client = -1;
    }
}

/// Publishes the authoritative window grid for the client's geometry seam
/// (embed patch 0006): the client's resize poll reads these vars instead of
/// `ioctl(TIOCGWINSZ)`, which returns ENOTSUP on sockets. Process-global by
/// design — only one embedded client runs at a time (crate docs, "stdio").
pub(crate) fn set_size_env(cols: u16, rows: u16) {
    std::env::set_var("HERDR_EMBED_COLS", cols.to_string());
    std::env::set_var("HERDR_EMBED_ROWS", rows.to_string());
}

/// Saves the current process-wide stdio by duplicating fds 0/1/2.
///
/// Returns one dup per stream (`-1` when that stream could not be saved).
/// The embed thread calls this immediately before redirecting stdio onto the
/// client socket; `herdr_embed_stop` restores from it after the client thread
/// joins, so the host process keeps its original stdio (on iOS: `/dev/null`).
pub(crate) fn save_stdio() -> [RawFd; 3] {
    let mut saved: [RawFd; 3] = [-1, -1, -1];
    for (index, fd) in [0, 1, 2].into_iter().enumerate() {
        // SAFETY: dup(2) of the live standard streams; results are owned by
        // the caller and closed after restore.
        let dup = unsafe { libc::dup(fd) };
        saved[index] = dup;
    }
    saved
}

/// Duplicates `saved` back onto fds 0/1/2 and closes the saved copies.
/// Entries that are `-1` are skipped (their stream could not be saved).
pub(crate) fn restore_stdio(saved: [RawFd; 3]) {
    for (target, source) in [0, 1, 2].into_iter().zip(saved) {
        if source < 0 {
            continue;
        }
        // SAFETY: dup2(2) between two non-conflicting fds we own; a failed
        // dup2 leaves the original target fd untouched, which is the best
        // available recovery mid-stop.
        if unsafe { libc::dup2(source, target) } < 0 {
            let _ = unsafe { libc::close(source) };
            continue;
        }
        // SAFETY: close(2) of the saved duplicate, exactly once.
        let _ = unsafe { libc::close(source) };
    }
}

/// Redirects fds 0/1/2 onto `client_fd` (the embed-thread half of the shim).
pub(crate) fn redirect_stdio_onto(client_fd: RawFd) -> io::Result<()> {
    for fd in [0, 1, 2] {
        // SAFETY: dup2(2) of a socket fd we own onto the standard streams;
        // failure past the first fd leaves a partially redirected stdio, but
        // the caller (embed thread) records the error and stop() still
        // restores the saved originals.
        if unsafe { libc::dup2(client_fd, fd) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Creates a non-blocking pipe used to cancel blocking `read_output` polls.
///
/// Apple libc has no `pipe2`, so the flags are set with `fcntl`.
pub(crate) fn wake_pipe() -> io::Result<[RawFd; 2]> {
    let mut fds: [RawFd; 2] = [-1, -1];
    // SAFETY: plain pipe(2) with valid out-parameters; both fds are owned by
    // the caller and closed by the instance teardown.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for fd in fds {
        // SAFETY: fcntl F_GETFL/F_SETFL on fds we own.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            let error = io::Error::last_os_error();
            for other in fds {
                if other >= 0 {
                    // SAFETY: close(2) cleanup of the half-built pipe.
                    let _ = unsafe { libc::close(other) };
                }
            }
            return Err(error);
        }
    }
    Ok(fds)
}

/// Lists currently open fds (best effort; used by the fd-hygiene tests).
#[cfg(test)]
pub(crate) fn open_fds() -> Vec<RawFd> {
    let mut fds = Vec::new();
    let entries = match fs::read_dir("/dev/fd") {
        Ok(entries) => entries,
        Err(_) => return fds,
    };
    for entry in entries.flatten() {
        if let Ok(fd) = entry.file_name().to_string_lossy().parse::<RawFd>() {
            fds.push(fd);
        }
    }
    fds.sort_unstable();
    fds
}

/// Lists open fds that are ttys — the design must keep this empty: the pty
/// path is deleted (the device sandbox denies openpty), so any tty fd here
/// means a pty crept back in.
#[cfg(test)]
pub(crate) fn tty_fds() -> Vec<RawFd> {
    open_fds()
        .into_iter()
        // SAFETY: isatty(2) only inspects the fd; numbers that close in
        // between simply report non-tty.
        .filter(|fd| *fd > 2 && unsafe { libc::isatty(*fd) } == 1)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every test here touches process-global state (fds 0/1/2, the fd
    /// table, env vars), so they serialize like the integration tests'
    /// `serial()` — parallel runs race fd-count assertions against the
    /// redirect test's transient dups.
    static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct SerialGuard(std::sync::MutexGuard<'static, ()>);
    impl Drop for SerialGuard {
        fn drop(&mut self) {}
    }

    fn serial() -> SerialGuard {
        SerialGuard(TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner()))
    }

    #[test]
    fn socketpair_pair_round_trips_bytes_and_leaks_no_fds() {
        let _serial = serial();
        let before = open_fds();
        {
            let pair = IoPair::open().expect("socketpair");
            // SAFETY: write(2) into the client end of the pair we own.
            let probe = b"roundtrip";
            assert_eq!(
                unsafe { libc::write(pair.client, probe.as_ptr().cast(), probe.len()) } as usize,
                probe.len()
            );
            let mut fds = [libc::pollfd {
                fd: pair.host,
                events: libc::POLLIN,
                revents: 0,
            }];
            // SAFETY: poll(2) readiness probe with a 2s cap so a broken
            // pair can never hang the suite.
            assert!(unsafe { libc::poll(fds.as_mut_ptr(), 1, 2000) } > 0);
            let mut buf = [0u8; 32];
            // SAFETY: read(2) from the host end under a fresh readable poll.
            let n = unsafe { libc::read(pair.host, buf.as_mut_ptr().cast(), buf.len()) };
            assert_eq!(&buf[..n as usize], probe, "bytes did not round-trip");
        }
        assert!(tty_fds().is_empty(), "a tty fd appeared in a socketpair design");
        assert_eq!(open_fds().len(), before.len());
    }

    #[test]
    fn host_end_is_non_blocking_and_client_end_is_blocking() {
        let _serial = serial();
        let pair = IoPair::open().expect("socketpair");
        // SAFETY: fcntl F_GETFL on fds the pair owns.
        let host_flags = unsafe { libc::fcntl(pair.host, libc::F_GETFL) };
        let client_flags = unsafe { libc::fcntl(pair.client, libc::F_GETFL) };
        assert!(host_flags >= 0 && client_flags >= 0);
        assert_ne!(host_flags & libc::O_NONBLOCK, 0, "host end must not block");
        assert_eq!(client_flags & libc::O_NONBLOCK, 0, "client end stays blocking");
    }

    #[test]
    fn set_size_env_publishes_the_grid_and_restores_cleanly() {
        let _serial = serial();
        let saved = (
            std::env::var("HERDR_EMBED_COLS").ok(),
            std::env::var("HERDR_EMBED_ROWS").ok(),
        );
        set_size_env(97, 31);
        assert_eq!(std::env::var("HERDR_EMBED_COLS").as_deref(), Ok("97"));
        assert_eq!(std::env::var("HERDR_EMBED_ROWS").as_deref(), Ok("31"));
        match saved {
            (Some(cols), Some(rows)) => {
                std::env::set_var("HERDR_EMBED_COLS", cols);
                std::env::set_var("HERDR_EMBED_ROWS", rows);
            }
            _ => {
                std::env::remove_var("HERDR_EMBED_COLS");
                std::env::remove_var("HERDR_EMBED_ROWS");
            }
        }
    }

    #[test]
    fn stdio_redirect_round_trips_verbatim_and_restore_reverses_it() {
        let _serial = serial();
        let was_tty: Vec<bool> = [0, 1, 2]
            .into_iter()
            // SAFETY: isatty(2) on the live standard streams.
            .map(|fd| unsafe { libc::isatty(fd) } == 1)
            .collect();
        let pair = IoPair::open().expect("socketpair");
        let saved = save_stdio();
        redirect_stdio_onto(pair.client).expect("dup2 stdio onto the client socket");
        let mut redirected_tty = [false; 3];
        for (index, fd) in [0, 1, 2].into_iter().enumerate() {
            // SAFETY: isatty(2) on the redirected standard streams.
            redirected_tty[index] = unsafe { libc::isatty(fd) } == 1;
        }
        // The design constraint the client patch compensates for: socketpair
        // stdio is NOT a tty, so crossterm's raw mode and tty detection must
        // be bypassed (embed patch 0006).
        assert!(
            redirected_tty.iter().all(|tty| !*tty),
            "socketpair stdio must not report as a tty"
        );
        // Host-side round trip: bytes written to the redirected stderr come
        // out of the host end VERBATIM (no pty line discipline, so no
        // LF→CRLF translation). Raw write(2) so a failure is captured as a
        // value instead of a panic whose message would vanish into the
        // redirected stream. The test harness's own fd-1 output can land in
        // the socketpair during the redirect window, so the host end is
        // drained first and the probe is matched as a contiguous subsequence
        // of the accumulated stream.
        let mut drain = [0u8; 256];
        loop {
            // SAFETY: read(2) on the non-blocking host end; EAGAIN (<= 0)
            // means drained.
            let n = unsafe { libc::read(pair.host, drain.as_mut_ptr().cast(), drain.len()) };
            if n <= 0 {
                break;
            }
        }
        let probe = b"\x1b[1mprobe\x1b[0m\n";
        // SAFETY: write(2) to the redirected stderr; rc captured for the
        // post-restore assertion.
        let written = unsafe { libc::write(2, probe.as_ptr().cast(), probe.len()) };
        restore_stdio(saved);
        assert_eq!(
            written, probe.len() as isize,
            "write to the redirected stderr failed"
        );
        let mut buf = [0u8; 4096];
        let mut fds = [libc::pollfd {
            fd: pair.host,
            events: libc::POLLIN,
            revents: 0,
        }];
        // SAFETY: poll(2) readiness probe with a 2s cap so a broken pair can
        // never hang the suite.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, 2000) };
        assert!(ready > 0, "no host-side data after the client-end write");
        // SAFETY: read(2) from the host fd the pair owns, under a fresh
        // readable poll.
        let n = unsafe { libc::read(pair.host, buf.as_mut_ptr().cast(), buf.len()) };
        assert!(n > 0, "no bytes round-tripped through the socketpair");
        assert!(
            buf[..n as usize]
                .windows(probe.len())
                .any(|window| window == &probe[..]),
            "socketpair must not translate bytes (read {:?})",
            &buf[..n as usize]
        );
        let now_tty: Vec<bool> = [0, 1, 2]
            .into_iter()
            // SAFETY: isatty(2) on the restored standard streams.
            .map(|fd| unsafe { libc::isatty(fd) } == 1)
            .collect();
        assert_eq!(now_tty, was_tty, "stdio was not restored");
        drop(pair);
        assert!(tty_fds().is_empty(), "fds survived the redirect cycle");
    }
}
