//! In-process embed FFI for the real herdr TUI client (plan
//! `.omo/plans/herdr-embed.md`, task 3).
//!
//! [`herdr_embed_start`] opens an AF_UNIX stream socketpair, spawns a thread
//! that dup2s the client end onto fds 0/1/2 and runs `herdr::run_client()`
//! there, and keeps the host end for the host: input via
//! [`herdr_embed_write_input`], rendered output via the cancellable blocking
//! [`herdr_embed_read_output`], resizes via [`herdr_embed_set_winsize`]
//! (explicit env-published grid — see "resize" below), teardown via
//! [`herdr_embed_stop`]. The client connects to the herdr server socket named
//! by `herdr_embed_config.socket_path` (env contract below).
//!
//! The pair is a socketpair, not a pty, because the iOS app sandbox denies
//! `openpty` with EPERM on physical devices (device probe 2026-09-17,
//! `.sisyphus/evidence/device-probe.log`) while socketpair/fcntl/dup2 are
//! legal there. Two consequences ripple into the client (embed patch 0006):
//! `isatty` is false on both ends, so crossterm raw mode and ratatui init are
//! bypassed when stdin is not a tty, and `ioctl(TIOCSWINSZ)` returns ENOTSUP
//! on sockets, so the window grid travels as explicit env state.
//!
//! FFI contract (mirrors herdr-ios-ffi):
//! * No Rust panic unwinds across the boundary; every entry point runs under
//!   [`catch`] and panics become `HERDR_EMBED_CODE_PANIC` results.
//! * `HerdrEmbedResult.detail` strings are borrowed, NUL-terminated UTF-8
//!   owned by the instance (or a thread-local for null-handle calls) until
//!   the next call on that instance; copy, never free.
//! * Unlike the herdr-ios-ffi client this instance IS safe for concurrent
//!   `read_output` / `write_input` / `set_winsize` / `is_running` calls from
//!   distinct threads (a blocking read must coexist with UI-thread writes).
//!   `herdr_embed_stop` consumes the handle: no other call may race it, and
//!   the handle is dead afterwards.
//!
//! ## Process-global facts (the honest list)
//!
//! * **stdio** — dup2 makes the client socket end the process-wide stdin/
//!   stdout/stderr. On iOS those point at `/dev/null`; the original fds are
//!   saved and restored by `herdr_embed_stop`. The client reads input from
//!   fd 0 and writes output to fd 1/2, so only ONE embedded client TUI may
//!   run at a time process-wide; a second start while one runs steals its
//!   stdio (socketpair+dup2 design constraint; multi-machine herds ride one
//!   client through its endpoint catalog instead).
//! * **resize** — there is no pty to size and no signal to steer:
//!   `ioctl(TIOCSWINSZ)` fails ENOTSUP on sockets (device probe,
//!   2026-09-17), so `set_winsize` publishes the authoritative grid through
//!   the `HERDR_EMBED_COLS`/`HERDR_EMBED_ROWS` env vars (embed patch 0006's
//!   geometry seam) and the client's 100ms resize poll re-reads them and
//!   re-renders. No SIGWINCH is raised and this crate installs no handler
//!   for it.
//! * **env** — `HERDR_CLIENT_SOCKET_PATH` is process-global; herdr resolves
//!   it once at the top of `run_client`. Starts serialize through a global
//!   gate: the embed thread re-asserts its socket path (and clears
//!   `HERDR_SOCKET_PATH`, which would otherwise win) immediately before
//!   `run_client`, and `start` waits for the thread to reach `run_client`.
//!   The residual cross-instance window is between that re-assert and the
//!   client's own env read; callers should start the next instance only
//!   after observing the previous instance's first output (its path has
//!   then been consumed).
mod abi;
mod instance;
mod stdio;

pub use abi::*;

use std::ffi::{c_char, CString};

/// Opaque embed handle; the allocation is owned by the caller and released
/// only through `herdr_embed_stop`. The C side never dereferences it.
#[repr(C)]
pub struct herdr_embed {
    _private: [u8; 0],
}

/// Start configuration. `socket_path` is required NUL-terminated UTF-8;
/// `cols`/`rows` seed the initial window grid published through the size
/// env (each 1..=65535). `detach_input` is the raw key sequence that
/// detaches the client (sent by `herdr_embed_stop` for a graceful quit);
/// null selects herdr's stock default, ctrl+b followed by q.
#[repr(C)]
pub struct herdr_embed_config {
    pub socket_path: *const c_char,
    pub cols: u16,
    pub rows: u16,
    pub detach_input: *const u8,
    pub detach_len: usize,
}

/// Structured errno-style call result; `detail` is a borrowed, NUL-terminated
/// UTF-8 diagnostic (null when code == HERDR_EMBED_CODE_OK).
#[repr(C)]
pub struct HerdrEmbedResult {
    pub code: i32,
    pub detail: *const c_char,
}

pub const HERDR_EMBED_CODE_OK: i32 = 0;
pub const HERDR_EMBED_CODE_INVALID_ARGUMENT: i32 = 1;
pub const HERDR_EMBED_CODE_PANIC: i32 = 2;
/// The client thread has exited or the instance is stopped.
pub const HERDR_EMBED_CODE_NOT_RUNNING: i32 = 3;
/// OS-level failure; detail carries the errno text.
pub const HERDR_EMBED_CODE_IO: i32 = 4;
/// stop() did not rejoin the client thread within its join budget; the
/// instance survives and stop may be retried.
pub const HERDR_EMBED_CODE_STOP_TIMEOUT: i32 = 5;

pub(crate) struct FfiError {
    pub code: i32,
    pub detail: CString,
}

impl FfiError {
    pub fn new(code: i32, detail: impl Into<String>) -> Self {
        let detail = CString::new(detail.into().replace('\0', "\\0"))
            .unwrap_or_else(|_| CString::new("malformed diagnostic").expect("static"));
        Self { code, detail }
    }
}

/// Runs `body` under catch_unwind so no panic unwinds into C.
pub(crate) fn catch<T>(body: impl FnOnce() -> Result<T, FfiError>) -> Result<T, FfiError> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(payload) => {
            let detail = if let Some(text) = payload.downcast_ref::<&str>() {
                (*text).to_owned()
            } else if let Some(text) = payload.downcast_ref::<String>() {
                text.clone()
            } else {
                "non-string rust panic payload".to_owned()
            };
            Err(FfiError::new(
                HERDR_EMBED_CODE_PANIC,
                format!("rust panic contained at FFI boundary: {detail}"),
            ))
        }
    }
}

thread_local! {
    /// Last error detail produced without an instance handle; overwritten by
    /// the next such call on that thread (same pattern as herdr-ios-ffi).
    static HANDLELESS_DETAIL: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").expect("static"));
}

pub(crate) fn ok_result() -> HerdrEmbedResult {
    HerdrEmbedResult {
        code: HERDR_EMBED_CODE_OK,
        detail: std::ptr::null(),
    }
}

pub(crate) fn invalid(detail: &'static str) -> FfiError {
    FfiError::new(HERDR_EMBED_CODE_INVALID_ARGUMENT, detail)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panics_are_contained_into_a_structured_error() {
        let error = catch::<()>(|| panic!("boom {x}", x = 7)).unwrap_err();
        assert_eq!(error.code, HERDR_EMBED_CODE_PANIC);
        assert!(error.detail.to_bytes().ends_with(b"boom 7"));
    }
}
