//! pty shim: `openpty` pair plus fd hygiene helpers (plan task 3).
//!
//! The pair is deliberately tiny: `master` stays with the embed instance for
//! input/output/winsize; `slave` is dup2'd onto fds 0/1/2 inside the embed
//! thread so `herdr::run_client`'s crossterm sees a real tty on the standard
//! streams (`isatty` passes) and writes its TUI frames where the host reads
//! them.
use std::io;
use std::os::unix::io::RawFd;
#[cfg(test)]
use std::fs;

pub(crate) struct PtyPair {
    pub master: RawFd,
    pub slave: RawFd,
}

impl PtyPair {
    /// Opens a new pty pair sized `cols` x `rows`.
    ///
    /// # Safety in ABI context
    /// `openpty` is a plain libc call; the SAFETY block below satisfies the
    /// workspace audit story for raw-pointer arguments.
    pub(crate) fn open(cols: u16, rows: u16) -> io::Result<Self> {
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        let size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: both out-parameters are valid ints for the call's duration;
        // `size` is read-only. On success both fds are owned by the returned
        // PtyPair and closed by its Drop.
        let mut size = size;
        let rc = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { master, slave })
    }

    #[cfg(test)]
    pub(crate) fn set_winsize(&self, cols: u16, rows: u16) -> io::Result<()> {
        set_fd_winsize(self.master, cols, rows)
    }

    #[cfg(test)]
    pub(crate) fn winsize(&self) -> io::Result<(u16, u16)> {
        fd_winsize(self.master)
    }

    /// Consumes the pair without closing: the master becomes the instance's
    /// read/write surface, the slave moves to the embed thread (which closes
    /// it after the dup2s). Callers own both fds from here on.
    pub(crate) fn into_parts(self) -> (RawFd, RawFd) {
        let pair = std::mem::ManuallyDrop::new(self);
        // SAFETY: ManuallyDrop keeps both fds open; the fields are plain ints
        // read once and the original Drop never runs.
        (pair.master, pair.slave)
    }
}

impl Drop for PtyPair {
    fn drop(&mut self) {
        for fd in [self.master, self.slave] {
            if fd >= 0 {
                // SAFETY: plain close(2) on fds this struct owns exactly once.
                let _ = unsafe { libc::close(fd) };
            }
        }
        self.master = -1;
        self.slave = -1;
    }
}

pub(crate) fn set_fd_winsize(fd: RawFd, cols: u16, rows: u16) -> io::Result<()> {
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: `size` is read-only for the ioctl's duration.
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
pub(crate) fn fd_winsize(fd: RawFd) -> io::Result<(u16, u16)> {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: `size` is a plain out-parameter for the ioctl's duration.
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((size.ws_col, size.ws_row))
}

/// Saves the current process-wide stdio by duplicating fds 0/1/2.
///
/// Returns one dup per stream (`-1` when that stream could not be saved).
/// The embed thread calls this immediately before redirecting stdio onto the
/// pty slave; `herdr_embed_stop` restores from it after the client thread
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

/// Redirects fds 0/1/2 onto `slave` (the embed-thread half of the shim).
pub(crate) fn redirect_stdio_onto(slave: RawFd) -> io::Result<()> {
    for fd in [0, 1, 2] {
        // SAFETY: dup2(2) of a pty slave fd we own onto the standard streams;
        // failure past the first fd leaves a partially redirected stdio, but
        // the caller (embed thread) records the error and stop() still
        // restores the saved originals.
        if unsafe { libc::dup2(slave, fd) } < 0 {
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

/// Blocks `signal` on the current thread. New threads inherit the mask, which
/// is how `herdr_embed_start` steers SIGWINCH away from host threads.
pub(crate) fn block_signal(signal: libc::c_int) -> io::Result<()> {
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: sigset_t manipulation on a local, properly sized object.
    if unsafe { libc::sigemptyset(&mut set) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::sigaddset(&mut set, signal) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pthread_sigmask only touches this thread's mask and the local set.
    if unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Unblocks `signal` on the current thread (embed-thread half of the design).
pub(crate) fn unblock_signal(signal: libc::c_int) {
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: same as block_signal; failures leave the inherited mask, which
    // only makes signal delivery less targeted, never wrong.
    if unsafe { libc::sigemptyset(&mut set) } == 0
        && unsafe { libc::sigaddset(&mut set, signal) } == 0
    {
        // SAFETY: see block_signal.
        let _ = unsafe { libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut()) };
    }
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

/// Lists open fds that are ttys — every pty the shim opens shows up here, so
/// the lifecycle tests assert this is empty after teardown.
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

    #[test]
    fn openpty_pair_reports_the_requested_winsize_and_leaks_no_fds() {
        let before = open_fds();
        {
            let pair = PtyPair::open(97, 31).expect("openpty");
            assert_eq!(pair.winsize().expect("TIOCGWINSZ"), (97, 31));
        }
        assert!(tty_fds().is_empty(), "pty fds survived PtyPair drop");
        assert_eq!(open_fds().len(), before.len());
    }

    #[test]
    fn winsize_updates_are_readable_back() {
        let pair = PtyPair::open(80, 24).expect("openpty");
        pair.set_winsize(120, 40).expect("TIOCSWINSZ");
        assert_eq!(pair.winsize().expect("TIOCGWINSZ"), (120, 40));
    }

    #[test]
    fn stdio_redirect_makes_standard_streams_tty_and_restore_reverses_it() {
        let was_tty: Vec<bool> = [0, 1, 2]
            .into_iter()
            // SAFETY: isatty(2) on the live standard streams.
            .map(|fd| unsafe { libc::isatty(fd) } == 1)
            .collect();
        let pair = PtyPair::open(80, 24).expect("openpty");
        let saved = save_stdio();
        redirect_stdio_onto(pair.slave).expect("dup2 stdio onto slave");
        let mut redirected_tty = [false; 3];
        for (index, fd) in [0, 1, 2].into_iter().enumerate() {
            // SAFETY: isatty(2) on the redirected standard streams.
            redirected_tty[index] = unsafe { libc::isatty(fd) } == 1;
        }
        // Master-side round trip: bytes written to the redirected stderr come
        // out of the pty master. Raw write(2) so a failure is captured as a
        // value instead of a panic whose message would vanish into the pty.
        let probe = b"\x1b[1mprobe\x1b[0m\n";
        // SAFETY: write(2) to the redirected stderr; rc captured for the
        // post-restore assertion.
        let written = unsafe { libc::write(2, probe.as_ptr().cast(), probe.len()) };
        restore_stdio(saved);
        assert!(redirected_tty.iter().all(|tty| *tty), "stdio is not the pty");
        assert_eq!(
            written, probe.len() as isize,
            "write to the redirected stderr failed"
        );
        let mut buf = [0u8; 32];
        let mut fds = [libc::pollfd {
            fd: pair.master,
            events: libc::POLLIN,
            revents: 0,
        }];
        // SAFETY: poll(2) readiness probe with a 2s cap so a broken pty can
        // never hang the suite.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, 2000) };
        assert!(ready > 0, "no master-side data after the slave write");
        // SAFETY: read(2) from the master fd the pair owns, under a fresh
        // readable poll.
        let n = unsafe { libc::read(pair.master, buf.as_mut_ptr().cast(), buf.len()) };
        assert!(n > 0, "no bytes round-tripped through the pty master");
        // The pty line discipline maps LF to CRLF (ONLCR) on the way out.
        assert_eq!(&buf[..n as usize], b"\x1b[1mprobe\x1b[0m\r\n");
        let now_tty: Vec<bool> = [0, 1, 2]
            .into_iter()
            // SAFETY: isatty(2) on the restored standard streams.
            .map(|fd| unsafe { libc::isatty(fd) } == 1)
            .collect();
        assert_eq!(now_tty, was_tty, "stdio was not restored");
        drop(pair);
        assert!(tty_fds().is_empty(), "pty fds survived the redirect cycle");
    }
}
