//! Shared helpers for the embed FFI integration tests. Every instance-level
//! test mutates process-global state (stdio via dup2, the socket env), so
//! they all serialize on [`serial`] and restore what they touch.
#![allow(dead_code)]
use herdr_ios_embed::{herdr_embed_config, herdr_embed_read_output, HerdrEmbedResult};
use std::ffi::CString;
use std::fs;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("crate lives at Vendor/herdr/herdr-ios-embed")
        .to_path_buf()
}

static SERIAL: Mutex<()> = Mutex::new(());

/// Panics during an instance's redirected-stdio window vanish into the
/// redirected stream;
/// mirror them into a repo-local file so failures stay diagnosable.
pub fn install_panic_log() {
    ONCE_PANIC_LOG.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let dir = repo_root().join(".build-artifacts/herdr-embed-test");
            let _ = fs::create_dir_all(&dir);
            use std::io::Write as _;
            if let Ok(mut file) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join(format!("panic-{}.log", std::process::id())))
            {
                let _ = writeln!(file, "{info}\n");
            }
        }));
    });
}

static ONCE_PANIC_LOG: std::sync::Once = std::sync::Once::new();

/// Serializes tests that flip process-global stdio/env. Held for the whole
/// test body.
pub fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

/// Restores HOME / HERDR_CONFIG_PATH / HERDR_SOCKET_PATH on drop while
/// pointing the client's config, data, and log writes at a repo-local dir.
pub struct ClientEnvGuard {
    home: Option<std::ffi::OsString>,
    config: Option<std::ffi::OsString>,
    socket: Option<std::ffi::OsString>,
    stderr_log: Option<std::ffi::OsString>,
}

impl Drop for ClientEnvGuard {
    fn drop(&mut self) {
        restore("HOME", &self.home);
        restore("HERDR_CONFIG_PATH", &self.config);
        restore("HERDR_SOCKET_PATH", &self.socket);
        restore("HERDR_EMBED_STDERR_LOG", &self.stderr_log);
    }
}

fn restore(name: &str, value: &Option<std::ffi::OsString>) {
    match value {
        Some(value) => std::env::set_var(name, value),
        None => std::env::remove_var(name),
    }
}

pub fn redirect_client_env(tag: &str) -> ClientEnvGuard {
    // No wipe here: test_dir(tag) is wiped by whichever fixture call comes
    // first in the test (ServerFixture::start or this guard in server-less
    // tests); wiping again would delete the other side's files.
    let dir = repo_root()
        .join(".build-artifacts/herdr-embed-test")
        .join(format!("{tag}-{}", std::process::id()));
    let home = dir.join("home");
    let config = dir.join("client-config.toml");
    fs::create_dir_all(&home).expect("create test home");
    fs::write(&config, "onboarding = false\n").expect("write client config");
    let guard = ClientEnvGuard {
        home: std::env::var_os("HOME"),
        config: std::env::var_os("HERDR_CONFIG_PATH"),
        socket: std::env::var_os("HERDR_SOCKET_PATH"),
        stderr_log: std::env::var_os("HERDR_EMBED_STDERR_LOG"),
    };
    std::env::remove_var("HERDR_SOCKET_PATH");
    std::env::set_var("HERDR_CONFIG_PATH", &config);
    std::env::set_var("HERDR_LOG", "herdr=debug");
    std::env::set_var("HOME", &home);
    std::env::set_var(
        "HERDR_EMBED_STDERR_LOG",
        dir.join("client-stderr.log"),
    );
    guard
}

/// Unique repo-local scratch dir for a test (wiped on entry).
pub fn test_dir(tag: &str) -> PathBuf {
    let dir = repo_root()
        .join(".build-artifacts/herdr-embed-test")
        .join(format!("{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create test dir");
    dir
}

/// Snapshot of the process fd table used for leak assertions.
pub fn fd_state() -> (usize, Vec<i32>) {
    let mut fds: Vec<i32> = fs::read_dir("/dev/fd")
        .expect("read /dev/fd")
        .flatten()
        .filter_map(|entry| entry.file_name().to_string_lossy().parse::<i32>().ok())
        .collect();
    fds.sort_unstable();
    let ttys = fds
        .iter()
        .copied()
        .filter(|fd| *fd > 2 && unsafe { libc::isatty(*fd) } == 1)
        .collect();
    (fds.len(), ttys)
}

pub struct InstanceGuard(*mut herdr_ios_embed::herdr_embed);

impl InstanceGuard {
    pub fn handle(&self) -> *mut herdr_ios_embed::herdr_embed {
        self.0
    }

    /// Stops through the ABI exactly once; the guard's Drop is then a no-op.
    pub fn stop(&mut self) -> HerdrEmbedResult {
        if self.0.is_null() {
            panic!("instance already stopped");
        }
        let result = herdr_ios_embed::herdr_embed_stop(self.0);
        self.0 = std::ptr::null_mut();
        result
    }
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        if self.0.is_null() {
            return;
        }
        let result = herdr_ios_embed::herdr_embed_stop(self.0);
        assert!(
            result.code == herdr_ios_embed::HERDR_EMBED_CODE_OK,
            "guard stop failed: {}",
            detail_text(result.detail)
        );
        self.0 = std::ptr::null_mut();
    }
}

pub fn detail_text(ptr: *const std::ffi::c_char) -> String {
    if ptr.is_null() {
        return "<null>".to_owned();
    }
    // SAFETY: borrowed ABI detail documented as NUL-terminated UTF-8 for the
    // duration of the call; copied immediately.
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

/// Starts an instance through the C ABI and stops it on scope exit.
pub fn start_instance(socket_path: &str, cols: u16, rows: u16) -> InstanceGuard {
    let socket = CString::new(socket_path).expect("socket path");
    let config = herdr_embed_config {
        socket_path: socket.as_ptr(),
        cols,
        rows,
        detach_input: std::ptr::null(),
        detach_len: 0,
    };
    let mut error = HerdrEmbedResult {
        code: -1,
        detail: std::ptr::null(),
    };
    let embed = unsafe {
        herdr_ios_embed::herdr_embed_start(&config, (&raw mut error).cast())
    };
    assert!(
        !embed.is_null(),
        "herdr_embed_start failed: {}",
        detail_text(error.detail)
    );
    InstanceGuard(embed)
}

/// Single-reader drain of `herdr_embed_read_output` on a worker thread; the
/// blocking read must not stall the test's wait deadlines, and it always
/// unblocks when the guard stops the instance.
pub struct OutputTap {
    rx: mpsc::Receiver<TapEvent>,
}

enum TapEvent {
    Bytes(Vec<u8>),
    Closed,
}

/// The raw ABI handle is not Send; the tap is the single reader and the
/// handle stays valid until the guard stops the instance.
struct SendHandle(*mut herdr_ios_embed::herdr_embed);
unsafe impl Send for SendHandle {}

/// Passing the wrapper through a function forces the spawned closure to
/// capture the whole SendHandle — a direct `handle.0` use would precise-capture
/// just the raw-pointer field and bypass the Send wrapper.
fn unwrap_handle(handle: SendHandle) -> *mut herdr_ios_embed::herdr_embed {
    let SendHandle(handle) = handle;
    handle
}

pub fn tap_output(handle: *mut herdr_ios_embed::herdr_embed) -> OutputTap {
    let (tx, rx) = mpsc::channel();
    let handle = SendHandle(handle);
    thread::spawn(move || {
        let handle = unwrap_handle(handle);
        let mut buf = [0u8; 8192];
        loop {
            let n = unsafe {
                herdr_embed_read_output(handle, buf.as_mut_ptr(), buf.len(), std::ptr::null_mut())
            };
            if n <= 0 {
                let _ = tx.send(TapEvent::Closed);
                return;
            }
            if tx.send(TapEvent::Bytes(buf[..n as usize].to_vec())).is_err() {
                return;
            }
        }
    });
    OutputTap { rx }
}

impl OutputTap {
    /// Accumulates output until `ready` accepts the accumulated bytes or the
    /// deadline passes; the accumulation is returned either way.
    pub fn wait_until(&self, ready: &dyn Fn(&[u8]) -> bool, timeout: Duration) -> (Vec<u8>, bool) {
        let mut acc: Vec<u8> = Vec::new();
        let deadline = Instant::now() + timeout;
        loop {
            if ready(&acc) {
                return (acc, true);
            }
            let now = Instant::now();
            if now >= deadline {
                return (acc, false);
            }
            match self.rx.recv_timeout(deadline - now) {
                Ok(TapEvent::Bytes(bytes)) => acc.extend_from_slice(&bytes),
                Ok(TapEvent::Closed) => return (acc, false),
                Err(mpsc::RecvTimeoutError::Timeout) => return (acc, false),
                Err(mpsc::RecvTimeoutError::Disconnected) => return (acc, false),
            }
        }
    }
}

/// Polls `probe` every 50ms until it true or the deadline passes.
pub fn poll_until(deadline: Duration, probe: &dyn Fn() -> bool) -> bool {
    let end = Instant::now() + deadline;
    loop {
        if probe() {
            return true;
        }
        if Instant::now() >= end {
            return false;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

/// The pinned prebuilt herdr server fixture binary (scripts/herdr-server-fetch.sh).
pub fn server_binary() -> PathBuf {
    repo_root().join("Fixtures/run/herdr/herdr")
}

pub struct ServerFixture {
    child: std::process::Child,
    pub dir: PathBuf,
    pub client_socket: PathBuf,
}

impl Drop for ServerFixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl ServerFixture {
    /// Starts an isolated `herdr server` on a repo-local UDS pair.
    pub fn start(tag: &str) -> ServerFixture {
        let bin = server_binary();
        assert!(
            bin.is_file(),
            "herdr server fixture missing at {} — run scripts/herdr-server-fetch.sh",
            bin.display()
        );
        let dir = test_dir(tag).join("server");
        let home = dir.join("home");
        fs::create_dir_all(&home).expect("create server home");
        let socket = dir.join("herdr.sock");
        let log = fs::File::create(dir.join("server.log")).expect("server log");
        let child = std::process::Command::new(&bin)
            .arg("server")
            .env("HERDR_SOCKET_PATH", &socket)
            .env("HOME", &home)
            .stdout(log.try_clone().expect("clone log"))
            .stderr(log)
            .stdin(std::process::Stdio::null())
            .spawn()
            .expect("spawn herdr server");
        let client_socket = dir.join("herdr-client.sock");
        let ready = poll_until(Duration::from_secs(15), &|| {
            UnixStream::connect(&client_socket).is_ok()
        });
        assert!(
            ready,
            "herdr server did not listen on {} (see {}/server.log)",
            client_socket.display(),
            dir.display()
        );
        ServerFixture {
            child,
            dir,
            client_socket,
        }
    }
}
