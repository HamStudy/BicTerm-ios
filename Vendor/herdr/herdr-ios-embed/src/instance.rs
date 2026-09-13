//! Embed instance machinery: the client thread, the pty master surface, and
//! the stop/join lifecycle behind the C API.
use std::ffi::CString;
use std::io;
use std::os::unix::io::RawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use crate::pty::{self, PtyPair};
use crate::{FfiError, HERDR_EMBED_CODE_IO, HERDR_EMBED_CODE_NOT_RUNNING};

/// How long `stop` waits for the client thread to unwind after the pty master
/// is closed (the client's event loop sees EOF and exits on its own). Well
/// under the 30s test-sleep ceiling; a timeout leaves the instance joinable —
/// calling `stop` again retries.
const STOP_JOIN_TIMEOUT: Duration = Duration::from_secs(15);

/// How long `start` waits for the embed thread to reach `run_client` before
/// releasing the process-global start gate (see the env contract in the crate
/// docs). The thread signals long before this unless the host is wedged.
const BOOT_GATE_TIMEOUT: Duration = Duration::from_secs(10);

/// Serializes starts and the process-global socket env writes (crate docs,
/// "env"). Held briefly — never across `run_client`.
static ENV_GATE: Mutex<()> = Mutex::new(());

/// Set by the crate's own SIGTERM handler (installed at start as the safety
/// net for kills that land before the client installs its ctrlc handler).
static TERMINATION_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn termination_requested_handler(_signal: libc::c_int) {
    TERMINATION_REQUESTED.store(true, Ordering::Release);
}

/// How long stop() gives the client's ctrlc handler (SIGTERM → should_quit →
/// clean unwind) before falling back to closing the pty master.
const TERM_GRACE: Duration = Duration::from_secs(3);

/// The embed thread's boot progress; `start` waits for `InRunClient`.
struct BootState {
    reached_run_client: bool,
}

struct Inner {
    socket_path: PathBuf,
    socket_path_c: CString,
    detach_input: Vec<u8>,
    master: AtomicI32,
    wake: [AtomicI32; 2],
    stopping: AtomicBool,
    client_exited: AtomicBool,
    saved_stdio: Mutex<Option<[RawFd; 3]>>,
    boot: Mutex<BootState>,
    boot_cv: Condvar,
    pub(crate) last_detail: Mutex<CString>,
    exit_detail: Mutex<Option<String>>,
}

impl Inner {
    fn wake_reader(&self) {
        let fd = self.wake[0].load(Ordering::Acquire);
        if fd < 0 {
            return;
        }
        let mut byte = [0u8; 64];
        loop {
            // SAFETY: read(2) on the non-blocking wake pipe this instance
            // owns; draining only, errors are terminal for the loop.
            let n = unsafe { libc::read(fd, byte.as_mut_ptr().cast(), byte.len()) };
            if n <= 0 {
                break;
            }
        }
    }

    fn notify_wake(&self) {
        let fd = self.wake[1].load(Ordering::Acquire);
        if fd < 0 {
            return;
        }
        // SAFETY: write(2) one byte into the non-blocking wake pipe; a full
        // pipe means a wake is already pending, so EAGAIN is success.
        let _ = unsafe { libc::write(fd, b"x".as_ptr().cast(), 1) };
    }

    pub(crate) fn store_detail(&self, error: &FfiError) {
        *self.last_detail.lock().unwrap_or_else(|e| e.into_inner()) = error.detail.clone();
    }

    fn record_exit(&self, outcome: &io::Result<()>) {
        let text = match outcome {
            Ok(()) => "client exited cleanly".to_owned(),
            Err(error) => format!("client thread ended: {error}"),
        };
        *self.exit_detail.lock().unwrap_or_else(|e| e.into_inner()) = Some(text);
        self.client_exited.store(true, Ordering::Release);
        // Unblock a read_output parked in poll: it must observe the exit.
        self.notify_wake();
    }
}

/// Rust-side instance. The C API hands out `*mut herdr_embed` pointing at a
/// `Box<EmbedInstance>`; `stop` takes the box back. All methods are safe for
/// concurrent `&self` use (a blocking read must coexist with UI-thread
/// writes); the join handle lives behind a Mutex so `stop` can take it once.
pub(crate) struct EmbedInstance {
    inner: Arc<Inner>,
    thread: Mutex<Option<JoinHandle<()>>>,
    done_rx: mpsc::Receiver<()>,
    finished: AtomicBool,
}

pub(crate) struct StartConfig {
    pub socket_path: String,
    pub cols: u16,
    pub rows: u16,
    /// Raw detach key sequence; empty selects the stock ctrl+b q default.
    pub detach_input: Vec<u8>,
}

pub(crate) fn start(config: StartConfig) -> io::Result<EmbedInstance> {
    let pair = PtyPair::open(config.cols, config.rows)?;
    let wake = pty::wake_pipe()?;
    let (master, slave) = pair.into_parts();

    // SIGWINCH steering (crate docs): the calling (host) thread — and every
    // thread created after — stops receiving SIGWINCH, so a process-directed
    // kill from set_winsize prefers the embed thread, which unblocks the
    // signal in itself. Failure here only makes delivery less targeted.
    let _ = pty::block_signal(libc::SIGWINCH);

    // SIGTERM safety net (crate docs, "stop"): until the client installs its
    // own ctrlc handler, a stop()-raised SIGTERM must not take the default
    // terminate-the-process action. The client's handler replaces this one
    // when it boots; the next start() reinstalls it.
    install_termination_handler();

    let socket_path_c = CString::new(config.socket_path.clone())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "socket path has an interior NUL"))?;
    let detach_input = if config.detach_input.is_empty() {
        b"\x02q".to_vec()
    } else {
        config.detach_input
    };
    let inner = Arc::new(Inner {
        socket_path: PathBuf::from(&config.socket_path),
        socket_path_c,
        detach_input,
        master: AtomicI32::new(master),
        wake: [AtomicI32::new(wake[0]), AtomicI32::new(wake[1])],
        stopping: AtomicBool::new(false),
        client_exited: AtomicBool::new(false),
        saved_stdio: Mutex::new(None),
        boot: Mutex::new(BootState {
            reached_run_client: false,
        }),
        boot_cv: Condvar::new(),
        last_detail: Mutex::new(CString::new("").expect("static")),
        exit_detail: Mutex::new(None),
    });

    let (done_tx, done_rx) = mpsc::channel::<()>();
    let thread_inner = Arc::clone(&inner);
    let thread = std::thread::Builder::new()
        .name("herdr-embed-client".to_owned())
        .spawn(move || {
            client_thread(thread_inner, slave);
            let _ = done_tx.send(());
        })
        .map_err(|error| {
            // PtyPair was consumed by into_parts; close both fds on the
            // error path so a failed spawn leaks nothing.
            for fd in [master, slave] {
                // SAFETY: close(2) of fds we own on the error path.
                if fd >= 0 {
                    let _ = unsafe { libc::close(fd) };
                }
            }
            for fd in wake {
                // SAFETY: close(2) of fds we own on the error path.
                if fd >= 0 {
                    let _ = unsafe { libc::close(fd) };
                }
            }
            error
        })?;

    {
        // Env gate: only the env write is serialized (crate docs, "env");
        // holding it across the boot wait would deadlock the thread's own
        // re-assert below.
        let gate = ENV_GATE.lock().unwrap_or_else(|e| e.into_inner());
        set_socket_env(&config.socket_path);
        drop(gate);
        let mut boot = inner
            .boot
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let deadline = std::time::Instant::now() + BOOT_GATE_TIMEOUT;
        while !boot.reached_run_client {
            let now = std::time::Instant::now();
            if now >= deadline {
                break;
            }
            let (guard, timeout) = inner
                .boot_cv
                .wait_timeout(boot, deadline - now)
                .unwrap_or_else(|e| e.into_inner());
            boot = guard;
            if timeout.timed_out() {
                break;
            }
        }
    }

    Ok(EmbedInstance {
        inner,
        thread: Mutex::new(Some(thread)),
        done_rx,
        finished: AtomicBool::new(false),
    })
}

/// Writes the process-global socket env consumed at the top of `run_client`.
/// Caller must hold `ENV_GATE`.
fn set_socket_env(socket_path: &str) {
    // HERDR_SOCKET_PATH would take precedence over HERDR_CLIENT_SOCKET_PATH
    // (upstream socket_paths precedence), so it is cleared to keep the
    // per-instance path authoritative.
    std::env::remove_var("HERDR_SOCKET_PATH");
    std::env::set_var("HERDR_CLIENT_SOCKET_PATH", socket_path);
}

// SAFETY: installing a flag-setting SIGTERM disposition; async-signal-safe
// (one atomic store) and SA_RESTART keeps blocking syscalls undisturbed.
fn install_termination_handler() {
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    action.sa_sigaction = termination_requested_handler as *const () as libc::sighandler_t;
    action.sa_flags = libc::SA_RESTART;
    unsafe { libc::sigemptyset(&mut action.sa_mask) };
    unsafe { libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut()) };
}

// SAFETY: dup2(2) of a freshly opened /dev/null onto the standard streams;
// the client's remaining writes/reads land on /dev/null instead of a closed
// pty. The saved originals are restored later by restore_stdio.
fn neuter_stdio() {
    // SAFETY: open(2) of a fixed kernel device path.
    let null_fd = unsafe { libc::open(b"/dev/null\0".as_ptr().cast(), libc::O_RDWR) };
    if null_fd < 0 {
        return;
    }
    for fd in [0, 1, 2] {
        // SAFETY: dup2(2) between two fds we own; failure leaves the
        // redirected pty in place, which restore_stdio still reverses.
        if unsafe { libc::dup2(null_fd, fd) } < 0 {
            break;
        }
    }
    // SAFETY: close(2) of the /dev/null fd; the dup2s above hold their own
    // references on the standard streams.
    let _ = unsafe { libc::close(null_fd) };
}

fn client_thread(inner: Arc<Inner>, slave: RawFd) {
    // Preferred SIGWINCH recipient (crate docs): this thread unblocks the
    // signal it inherited blocked from the spawning host thread.
    pty::unblock_signal(libc::SIGWINCH);

    {
        let gate = ENV_GATE.lock().unwrap_or_else(|e| e.into_inner());
        let _gate = gate;
        // Re-assert this instance's path as the thread's first action: start
        // set it just before spawn, but the thread re-writing it under the
        // gate shrinks the cross-instance race to the window between this
        // unlock and run_client's own env read (documented residual window).
        set_socket_env(&inner.socket_path.to_string_lossy());
    }

    let saved = pty::save_stdio();
    let redirect = pty::redirect_stdio_onto(slave);
    // Diagnostic escape hatch (crate docs): route the client's stderr to a
    // file instead of the pty so final error messages survive teardown —
    // on iOS the process stderr is /dev/null anyway.
    if let Ok(path) = std::env::var("HERDR_EMBED_STDERR_LOG") {
        if let Ok(cpath) = std::ffi::CString::new(path) {
            // SAFETY: open(2) with a NUL-terminated path we just built; the
            // fd replaces the redirected stderr via dup2 below.
            let log_fd = unsafe {
                libc::open(
                    cpath.as_ptr(),
                    libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
                    0o600,
                )
            };
            if log_fd >= 0 {
                // SAFETY: dup2(2) of the log fd onto fd 2; the original
                // (pty) stderr dup is closed after.
                if unsafe { libc::dup2(log_fd, 2) } >= 0 {
                    let _ = unsafe { libc::close(log_fd) };
                } else {
                    let _ = unsafe { libc::close(log_fd) };
                }
            }
        }
    }
    // SAFETY: the slave fd is consumed by the dup2s above (or leaked on
    // failure only until process exit — a failed dup2 leaves it open but the
    // master close in stop still tears the pty down).
    let _ = unsafe { libc::close(slave) };
    *inner.saved_stdio.lock().unwrap_or_else(|e| e.into_inner()) = Some(saved);
    if let Err(error) = redirect {
        inner.record_exit(&Err(io::Error::other(format!(
            "stdio redirect onto the pty failed: {error}"
        ))));
        return;
    }

    {
        let mut boot = inner.boot.lock().unwrap_or_else(|e| e.into_inner());
        boot.reached_run_client = true;
        inner.boot_cv.notify_all();
    }

    let outcome = herdr::run_client();
    inner.record_exit(&outcome);
}

impl EmbedInstance {
    fn wait_for_exit(&self, budget: Duration) -> bool {
        let deadline = std::time::Instant::now() + budget;
        while !self.inner.client_exited.load(Ordering::Acquire)
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(50));
        }
        self.inner.client_exited.load(Ordering::Acquire)
    }

    /// Best-effort single write of the detach key sequence into the master.
    /// One syscall on purpose: a client that stopped reading must not block
    /// stop() on a full pty buffer.
    fn send_detach_input(&self) {
        let master = self.inner.master.load(Ordering::Acquire);
        if master < 0 || self.inner.detach_input.is_empty() {
            return;
        }
        // SAFETY: write(2) of the instance-owned detach bytes into the pty
        // master; partial writes are acceptable (best effort).
        unsafe {
            libc::write(
                master,
                self.inner.detach_input.as_ptr().cast(),
                self.inner.detach_input.len(),
            )
        };
    }

    pub(crate) fn socket_path_c(&self) -> &CString {
        &self.inner.socket_path_c
    }

    /// Parks `error`'s detail in the instance (borrowed by the ABI layer
    /// until the instance's next call).
    pub(crate) fn store_detail(&self, error: &FfiError) {
        self.inner.store_detail(error);
    }

    pub(crate) fn detail_ptr(&self) -> *const std::ffi::c_char {
        self.inner
            .last_detail
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ptr()
    }

    pub(crate) fn is_running(&self) -> bool {
        !self.inner.stopping.load(Ordering::Acquire)
            && !self.inner.client_exited.load(Ordering::Acquire)
    }

    /// Blocking, cancellable read from the pty master. Returns `Ok(0)` when
    /// the instance stopped or the client exited with nothing more to drain;
    /// `Ok(n)` with client bytes otherwise.
    pub(crate) fn read_output(&self, buf: &mut [u8]) -> Result<usize, FfiError> {
        if buf.is_empty() {
            return Err(FfiError::new(
                crate::HERDR_EMBED_CODE_INVALID_ARGUMENT,
                "output buffer capacity is zero",
            ));
        }
        loop {
            if self.inner.stopping.load(Ordering::Acquire) {
                return Ok(0);
            }
            let master = self.inner.master.load(Ordering::Acquire);
            let wake_rx = self.inner.wake[0].load(Ordering::Acquire);
            // After the client exits the slave stays open through the
            // redirected stdio fds, so the master never EOFs on its own; a
            // bounded poll keeps draining until stop closes it. The exit
            // wake is one-shot and may already be consumed.
            let exited = self.inner.client_exited.load(Ordering::Acquire);
            let timeout_ms: libc::c_int = if exited { 100 } else { -1 };
            let mut fds = [
                libc::pollfd {
                    fd: master,
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: wake_rx,
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // SAFETY: poll(2) over fds the instance owns for its lifetime;
            // negative fds are ignored by poll by definition. The wake pipe
            // bounds the block: stop/exit wake it deterministically.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout_ms) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(FfiError::new(HERDR_EMBED_CODE_IO, format!("poll: {error}")));
            }
            if fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                self.inner.wake_reader();
                if self.inner.stopping.load(Ordering::Acquire) {
                    return Ok(0);
                }
            }
            if master >= 0 && fds[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                // SAFETY: read(2) into the caller-provided buffer of exactly
                // buf.len() bytes; the C ABI documents the borrow for the call.
                let n = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
                if n > 0 {
                    return Ok(n as usize);
                }
                if n == 0 {
                    return Ok(0);
                }
                let error = io::Error::last_os_error();
                match error.kind() {
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock => continue,
                    _ => {
                        if self.inner.client_exited.load(Ordering::Acquire) {
                            return Ok(0);
                        }
                        return Err(FfiError::new(HERDR_EMBED_CODE_IO, format!("read: {error}")));
                    }
                }
            } else if master >= 0 && fds[0].revents & libc::POLLNVAL != 0 {
                // Closed underneath us by a concurrent stop.
                return Ok(0);
            }
            if self.inner.client_exited.load(Ordering::Acquire) {
                // Exit wake: one last poll for buffered master bytes, then EOF.
                if master >= 0 {
                    let mut probe = [libc::pollfd {
                        fd: master,
                        events: libc::POLLIN,
                        revents: 0,
                    }];
                    // SAFETY: poll(2) with a zero timeout — a pure readiness probe.
                    if unsafe { libc::poll(probe.as_mut_ptr(), 1, 0) } > 0
                        && probe[0].revents & (libc::POLLIN | libc::POLLHUP) != 0
                    {
                        // SAFETY: read(2) as above, under a fresh readable poll.
                        let n = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
                        if n > 0 {
                            return Ok(n as usize);
                        }
                    }
                }
                return Ok(0);
            }
        }
    }

    pub(crate) fn write_input(&self, bytes: &[u8]) -> Result<(), FfiError> {
        if bytes.is_empty() {
            return Ok(());
        }
        let master = self.inner.master.load(Ordering::Acquire);
        if master < 0
            || self.inner.stopping.load(Ordering::Acquire)
            || self.inner.client_exited.load(Ordering::Acquire)
        {
            return Err(FfiError::new(
                HERDR_EMBED_CODE_NOT_RUNNING,
                "the embedded client is not running",
            ));
        }
        let mut written = 0usize;
        while written < bytes.len() {
            // SAFETY: write(2) from the caller-provided slice of exactly
            // bytes.len() bytes, documented as borrowed for the call.
            let n = unsafe {
                libc::write(master, bytes[written..].as_ptr().cast(), bytes.len() - written)
            };
            if n >= 0 {
                written += n as usize;
                continue;
            }
            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => continue,
                // A full pty buffer means the client stopped draining; treat
                // like a dead client rather than blocking the caller forever.
                io::ErrorKind::WouldBlock => {
                    return Err(FfiError::new(
                        HERDR_EMBED_CODE_IO,
                        "pty input buffer is full (client stopped reading)",
                    ))
                }
                _ => {
                    return Err(FfiError::new(
                        HERDR_EMBED_CODE_NOT_RUNNING,
                        format!("write: {error}"),
                    ))
                }
            }
        }
        let _ = written;
        Ok(())
    }

    /// Applies the new size to the pty and raises SIGWINCH process-wide
    /// (crate docs: the embedded client's crossterm owns the handler).
    pub(crate) fn set_winsize(&self, cols: u16, rows: u16) -> Result<(), FfiError> {
        let master = self.inner.master.load(Ordering::Acquire);
        if master < 0 {
            return Err(FfiError::new(
                HERDR_EMBED_CODE_NOT_RUNNING,
                "the embedded client is not running",
            ));
        }
        pty::set_fd_winsize(master, cols, rows)
            .map_err(|error| FfiError::new(HERDR_EMBED_CODE_IO, format!("TIOCSWINSZ: {error}")))?;
        // SAFETY: kill(2) directed at our own process; the signal has a
        // process-wide handler installed by the embedded client (or none yet,
        // in which case the default action is ignore).
        if unsafe { libc::kill(libc::getpid(), libc::SIGWINCH) } != 0 {
            let error = io::Error::last_os_error();
            return Err(FfiError::new(HERDR_EMBED_CODE_IO, format!("kill SIGWINCH: {error}")));
        }
        Ok(())
    }

    /// Teardown: ask the client to quit gracefully by sending its detach key
    /// sequence (the same bytes the user's detach gesture produces), then
    /// raise SIGTERM (the client's ctrlc handler sets should_quit — note the
    /// ctrlc Apple backend only honors the FIRST client's handler in a
    /// process, so the detach input is the primary path), then close the
    /// master, join the client thread, restore stdio, and close the wake
    /// pipe. On timeout the instance survives and `stop` may be retried.
    pub(crate) fn stop(&self) -> Result<(), FfiError> {
        if self.finished.load(Ordering::Acquire) {
            return Ok(());
        }
        self.inner.stopping.store(true, Ordering::Release);
        self.inner.notify_wake();
        if !self.inner.client_exited.load(Ordering::Acquire) {
            self.send_detach_input();
            if !self.wait_for_exit(TERM_GRACE) {
                // SAFETY: kill(2) directed at our own process; a client
                // handler (ctrlc or the crate's start-installed safety net)
                // always holds the disposition by the time a client is
                // running, so the default terminate action cannot fire.
                unsafe { libc::kill(libc::getpid(), libc::SIGTERM) };
                self.wait_for_exit(TERM_GRACE);
            }
        }
        let master = self.inner.master.swap(-1, Ordering::AcqRel);
        if master >= 0 {
            // SAFETY: close(2) of the master fd this instance owns exactly once.
            let _ = unsafe { libc::close(master) };
            // Neuter the client's stdio AFTER the master close: the close
            // wakes any thread blocked reading the pty (a dup2 over an fd
            // another thread is blocked reading deadlocks on Darwin), and
            // the client's later writes must land on /dev/null rather than
            // fail with EIO on the closed pty (an EIO write maps to a client
            // error path that calls process::exit(1) — fatal in-process).
            neuter_stdio();
        }
        let join_deadline = std::time::Instant::now() + STOP_JOIN_TIMEOUT;
        loop {
            match self.done_rx.recv_timeout(STOP_JOIN_TIMEOUT.min(join_deadline - std::time::Instant::now())) {
                Ok(()) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if std::time::Instant::now() >= join_deadline {
                        let detail = self
                            .inner
                            .exit_detail
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .clone()
                            .unwrap_or_else(|| {
                                "client thread did not exit within the stop join budget".to_owned()
                            });
                        return Err(FfiError::new(
                            crate::HERDR_EMBED_CODE_STOP_TIMEOUT,
                            format!("stop timed out joining the client thread: {detail}"),
                        ));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        self.finished.store(true, Ordering::Release);
        // The join itself is instant now that done_rx fired; the Mutex keeps
        // concurrent ABI callers from aliasing the handle.
        if let Some(thread) = self
            .thread
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            let _ = thread.join();
        }
        if let Some(saved) = self
            .inner
            .saved_stdio
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            pty::restore_stdio(saved);
        }
        for slot in &self.inner.wake {
            let fd = slot.swap(-1, Ordering::AcqRel);
            if fd >= 0 {
                // SAFETY: close(2) of the wake pipe fds owned here, once.
                let _ = unsafe { libc::close(fd) };
            }
        }
        Ok(())
    }
}
