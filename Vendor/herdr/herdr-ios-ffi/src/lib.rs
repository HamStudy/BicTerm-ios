//! Panic-safe C ABI over `herdr-client-core` (doc `HERDR_IOS_INTEGRATION.md` §3.2).
//!
//! FFI contract:
//! * No Rust panic unwinds across the boundary: every entry point runs under
//!   [`catch`] and panics become structured `HERDR_CODE_PANIC` results.
//! * Single documented owner per allocation: clients are freed by
//!   `herdr_client_destroy`, byte buffers by `herdr_bytes_free`. Each buffer
//!   must be freed exactly once; double-free is undefined behavior.
//! * Borrowed error detail strings (`HerdrResult.detail`) are UTF-8,
//!   NUL-terminated, and owned by the client until its next call (or static
//!   for create-time errors); callers must copy, never free them.
//! * The client is NOT thread-safe: confine it to one serial executor/actor.
mod abi;
mod abi_query;
mod client;
mod client_activation;
mod clipboard;
mod errors;
mod factory;
mod frame;
mod input_map;
mod support;

pub use abi::*;
pub use abi_query::*;

use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicU64, Ordering};

/// Opaque client handle; the pointed-to allocation is owned by the caller and
/// released only through `herdr_client_destroy`. The C side never dereferences
/// it — every ABI call casts back to the Rust payload internally.
#[repr(C)]
pub struct herdr_client {
    _private: [u8; 0],
}

/// Integer widths and nullable rules are explicit per field; all strings are
/// UTF-8 and NUL-terminated unless a length is provided instead.
#[repr(C)]
pub struct herdr_client_config {
    /// Logical surface columns; must be 1..=u16::MAX.
    pub cols: u32,
    /// Logical surface rows; must be 1..=u16::MAX.
    pub rows: u32,
    /// Cell width in physical pixels (0 when unknown).
    pub cell_width_px: u32,
    /// Cell height in physical pixels (0 when unknown).
    pub cell_height_px: u32,
    /// Advertise SGR pixel-mouse support only with exact geometry (doc §7).
    pub pixel_mouse: bool,
    /// Advertise shell mouse capture only when pointer capture is implemented.
    pub mouse_capture: bool,
    /// Inbound frame-size ceiling; 0 selects the protocol default.
    pub max_frame_size: u32,
    /// Outbound queue message budget; 0 selects the default (256).
    pub outbound_message_limit: u32,
    /// Outbound queue byte budget; 0 selects the default (4 MiB).
    pub outbound_byte_limit: u32,
}

/// One semantic pane input event, routed to an explicit pane identity.
#[repr(C)]
pub struct herdr_input {
    /// HERDR_INPUT_TEXT_COMMIT, HERDR_INPUT_KEY, or HERDR_INPUT_PASTE.
    pub kind: u8,
    /// NUL-terminated UTF-8 pane id from the latest snapshot; required.
    pub pane_id: *const c_char,
    /// NUL-terminated UTF-8 text; required for TEXT_COMMIT and PASTE, else null.
    pub text: *const c_char,
    /// Key payload; read only when `kind == HERDR_INPUT_KEY`.
    pub key: herdr_key,
}

#[derive(Clone, Copy)]
#[repr(C)]
pub struct herdr_key {
    /// HERDR_KEY_* constant; CHAR and FUNCTION read `codepoint`.
    pub code: u32,
    /// Unicode scalar (CHAR) or function-key number 1..=35 (FUNCTION).
    pub codepoint: u32,
    /// Crossterm-compatible modifier bits.
    pub modifiers: u8,
    /// HERDR_KEY_KIND_PRESS/REPEAT/RELEASE.
    pub kind: u8,
    pub repeat_count: u16,
    /// Shifted unicode scalar; 0 when unavailable.
    pub shifted_codepoint: u32,
}

/// Rust-owned byte buffer. `data` is null iff `len == 0`; ownership moves to
/// the caller and returns via `herdr_bytes_free` exactly once.
#[repr(C)]
pub struct herdr_bytes {
    pub data: *mut u8,
    pub len: usize,
}

/// Structured call result; `detail` is a borrowed, NUL-terminated UTF-8
/// diagnostic (null when code == HERDR_CODE_OK).
#[repr(C)]
pub struct HerdrResult {
    pub code: i32,
    pub detail: *const c_char,
}

pub const HERDR_CODE_OK: i32 = 0;
pub const HERDR_CODE_INVALID_ARGUMENT: i32 = 1;
pub const HERDR_CODE_PANIC: i32 = 2;
pub const HERDR_CODE_DISCONNECTED: i32 = 3;
pub const HERDR_CODE_PROTOCOL_VIOLATION: i32 = 4;
pub const HERDR_CODE_HANDSHAKE_TIMED_OUT: i32 = 5;
pub const HERDR_CODE_HANDSHAKE_EXPECTED_WELCOME: i32 = 6;
pub const HERDR_CODE_HANDSHAKE_INVALID_WELCOME: i32 = 7;
pub const HERDR_CODE_HANDSHAKE_INCOMPATIBLE: i32 = 8;
pub const HERDR_CODE_HANDSHAKE_REJECTED: i32 = 9;
pub const HERDR_CODE_NOT_ONLINE: i32 = 10;
pub const HERDR_CODE_INPUT_FROZEN: i32 = 11;
pub const HERDR_CODE_INPUT_STALE_TARGET: i32 = 12;
pub const HERDR_CODE_INPUT_WRITE_FAILED: i32 = 13;
pub const HERDR_CODE_SURFACE_REJECTED: i32 = 14;
pub const HERDR_CODE_CLIENT_FAILED: i32 = 15;
/// Non-fatal: a server clipboard frame was dropped (oversized or malformed
/// base64). The client stays Online; the receive call reports this detail.
pub const HERDR_CODE_CLIPBOARD_DROPPED: i32 = 16;

pub const HERDR_INPUT_TEXT_COMMIT: u8 = 0;
pub const HERDR_INPUT_KEY: u8 = 1;
pub const HERDR_INPUT_PASTE: u8 = 2;

pub const HERDR_KEY_BACKSPACE: u32 = 1;
pub const HERDR_KEY_ENTER: u32 = 2;
pub const HERDR_KEY_LEFT: u32 = 3;
pub const HERDR_KEY_RIGHT: u32 = 4;
pub const HERDR_KEY_UP: u32 = 5;
pub const HERDR_KEY_DOWN: u32 = 6;
pub const HERDR_KEY_HOME: u32 = 7;
pub const HERDR_KEY_END: u32 = 8;
pub const HERDR_KEY_PAGE_UP: u32 = 9;
pub const HERDR_KEY_PAGE_DOWN: u32 = 10;
pub const HERDR_KEY_TAB: u32 = 11;
pub const HERDR_KEY_BACK_TAB: u32 = 12;
pub const HERDR_KEY_DELETE: u32 = 13;
pub const HERDR_KEY_INSERT: u32 = 14;
pub const HERDR_KEY_ESC: u32 = 15;
pub const HERDR_KEY_CHAR: u32 = 16;
pub const HERDR_KEY_FUNCTION: u32 = 17;
pub const HERDR_KEY_NULL: u32 = 18;

pub const HERDR_KEY_KIND_PRESS: u8 = 0;
pub const HERDR_KEY_KIND_REPEAT: u8 = 1;
pub const HERDR_KEY_KIND_RELEASE: u8 = 2;

pub const HERDR_PHASE_AWAITING_WELCOME: u32 = 0;
pub const HERDR_PHASE_ONLINE: u32 = 1;
pub const HERDR_PHASE_FAILED: u32 = 2;

/// Error detail with a stable storage story: static text for create-time
/// failures, client-owned text for per-call failures.
pub(crate) struct FfiError {
    pub code: i32,
    pub detail: CString,
}

impl FfiError {
    pub fn new(code: i32, detail: impl Into<String>) -> Self {
        // CString::new fails only on interior NUL bytes, which never appear in
        // the diagnostics built here; mapping to a placeholder keeps the
        // constructor total instead of adding an impossible error path.
        let detail = CString::new(detail.into().replace('\0', "\\0"))
            .unwrap_or_else(|_| CString::new("malformed diagnostic").expect("static"));
        Self { code, detail }
    }
}

/// Runs `body` under `catch_unwind`, converting any panic into a structured
/// `HERDR_CODE_PANIC` error instead of unwinding into C.
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
                HERDR_CODE_PANIC,
                format!("rust panic contained at FFI boundary: {detail}"),
            ))
        }
    }
}

/// Live allocation ledger backing `herdr_debug_live_allocations`; every
/// allocation handed to C (clients, byte buffers) is paired with exactly one
/// free received back from C.
static LIVE_ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

pub(crate) fn track_allocation() {
    LIVE_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
}

pub(crate) fn track_free() {
    let live = LIVE_ALLOCATIONS.fetch_sub(1, Ordering::Relaxed);
    debug_assert!(live > 0, "free without matching allocation");
}

pub(crate) fn debug_live_allocations() -> u64 {
    LIVE_ALLOCATIONS.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panics_are_contained_into_a_structured_error() {
        let error = catch::<()>(|| panic!("boom {detail}", detail = 42)).unwrap_err();
        assert_eq!(error.code, HERDR_CODE_PANIC);
        assert!(error.detail.to_bytes().ends_with(b"boom 42"));
    }

    #[test]
    fn non_string_panic_payloads_are_reported() {
        let error = catch::<()>(|| std::panic::panic_any(0xdead_beef_u32)).unwrap_err();
        assert!(error
            .detail
            .to_bytes()
            .ends_with(b"non-string rust panic payload"));
    }
}
