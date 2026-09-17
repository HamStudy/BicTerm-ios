//! `#[no_mangle]` C surface. Every entry point runs under [`crate::catch`];
//! pointer crossings carry SAFETY arguments (herdr-ios-ffi conventions).
use crate::instance::{self, EmbedInstance};
use crate::{
    catch, herdr_embed, herdr_embed_config, invalid, ok_result, FfiError, HerdrEmbedResult,
};
use std::ffi::{c_char, CStr, CString};
use std::ptr;

thread_local! {
    /// Last error detail produced without an instance handle; overwritten by
    /// the next such call on that thread (same pattern as herdr-ios-ffi).
    static HANDLELESS_DETAIL: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").expect("static"));
}

/// Parks a handle-less error detail in the thread-local slot.
fn handleless_result(error: FfiError) -> HerdrEmbedResult {
    let code = error.code;
    HANDLELESS_DETAIL.with(|slot| {
        *slot.borrow_mut() = error.detail;
        HerdrEmbedResult {
            code,
            detail: slot.borrow().as_ptr(),
        }
    })
}

fn flatten(embed: *mut herdr_embed, result: Result<(), FfiError>) -> HerdrEmbedResult {
    match result {
        Ok(()) => ok_result(),
        Err(error) => {
            if embed.is_null() {
                handleless_result(error)
            } else {
                // SAFETY: non-null, live handle per the ABI contract.
                let instance = unsafe { instance_ref(embed) };
                let code = error.code;
                instance.store_detail(&error);
                HerdrEmbedResult {
                    code,
                    detail: instance.detail_ptr(),
                }
            }
        }
    }
}

/// SAFETY in ABI context (not a Rust-safe API): the handle must be non-null,
/// originate from `herdr_embed_start`, not yet be stopped, and not be used
/// concurrently with `herdr_embed_stop`; the returned reference is valid for
/// the duration of the current ABI call only.
unsafe fn instance_ref<'a>(embed: *mut herdr_embed) -> &'a EmbedInstance {
    &*embed.cast()
}

// SAFETY: writing a plain C struct through a caller-provided out-pointer; the
// pointer is non-null and properly aligned per the C calling convention.
unsafe fn write_error_out(error_out: *mut HerdrEmbedResult, result: HerdrEmbedResult) {
    if !error_out.is_null() {
        unsafe { ptr::write_unaligned(error_out, result) };
    }
}

/// Starts the embedded client against a new socketpair. Returns null on
/// failure with the structured reason in `error_out` (optional). The returned
/// handle is released by `herdr_embed_stop` — there is no separate destroy.
#[no_mangle]
pub extern "C" fn herdr_embed_start(
    config: *const herdr_embed_config,
    error_out: *mut HerdrEmbedResult,
) -> *mut herdr_embed {
    let result = catch(|| {
        if config.is_null() {
            return Err(invalid("config pointer is null"));
        }
        // SAFETY: caller provides a readable config for the call's duration.
        let config = unsafe { &*config };
        if config.socket_path.is_null() {
            return Err(invalid("socket_path pointer is null"));
        }
        // SAFETY: caller provides a NUL-terminated UTF-8 string.
        let bytes = unsafe { CStr::from_ptr(config.socket_path) }.to_bytes();
        let socket_path = std::str::from_utf8(bytes)
            .map_err(|_| invalid("socket_path is not UTF-8"))?
            .to_owned();
        if socket_path.is_empty() {
            return Err(invalid("socket_path is required"));
        }
        if config.cols == 0 || config.rows == 0 {
            return Err(invalid("cols and rows must each be 1..=65535"));
        }
        let detach_input = if config.detach_len == 0 {
            Vec::new()
        } else {
            if config.detach_input.is_null() {
                return Err(invalid(
                    "detach_input pointer is null with a non-zero length",
                ));
            }
            // SAFETY: caller provides `detach_len` readable bytes for the
            // call; copied into the instance and never retained.
            unsafe { std::slice::from_raw_parts(config.detach_input, config.detach_len) }.to_vec()
        };
        instance::start(instance::StartConfig {
            socket_path,
            cols: config.cols,
            rows: config.rows,
            detach_input,
        })
        .map_err(|error| FfiError::new(crate::HERDR_EMBED_CODE_IO, format!("start: {error}")))
    });
    match result {
        Ok(inner) => {
            // SAFETY: writing the caller's optional out-param.
            unsafe { write_error_out(error_out, ok_result()) };
            // SAFETY: fresh allocation handed to C as the opaque handle; the
            // only way back is herdr_embed_stop's cast below.
            Box::into_raw(Box::new(inner)).cast::<herdr_embed>()
        }
        Err(error) => {
            // SAFETY: writing the caller's optional out-param.
            unsafe { write_error_out(error_out, handleless_result(error)) };
            ptr::null_mut()
        }
    }
}

/// Feeds raw input bytes (keys, paste) to the client through the host socket.
#[no_mangle]
pub extern "C" fn herdr_embed_write_input(
    embed: *mut herdr_embed,
    bytes: *const u8,
    len: usize,
) -> HerdrEmbedResult {
    let result = catch(|| {
        if embed.is_null() {
            return Err(invalid("embed pointer is null"));
        }
        if len == 0 {
            return Ok(());
        }
        if bytes.is_null() {
            return Err(invalid("bytes pointer is null with a non-zero length"));
        }
        // SAFETY: caller provides `len` readable bytes for the call; the
        // slice is copied into the socket and never retained.
        let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
        // SAFETY: non-null, live handle per the ABI contract.
        unsafe { instance_ref(embed) }.write_input(bytes)
    });
    flatten(embed, result)
}

/// Blocking, cancellable read of client output into the caller's buffer.
/// Returns the byte count (>0), 0 when the instance stopped or the client
/// exited with nothing left to drain, or -1 with the reason in `error_out`.
#[no_mangle]
pub extern "C" fn herdr_embed_read_output(
    embed: *mut herdr_embed,
    buf: *mut u8,
    capacity: usize,
    error_out: *mut HerdrEmbedResult,
) -> i64 {
    let result = catch(|| {
        if embed.is_null() {
            return Err(invalid("embed pointer is null"));
        }
        if capacity == 0 {
            return Err(invalid("output buffer capacity is zero"));
        }
        if buf.is_null() {
            return Err(invalid("buffer pointer is null with a non-zero capacity"));
        }
        // SAFETY: caller provides `capacity` writable bytes for the call; the
        // bytes are filled from the host socket and returned by count.
        let buf = unsafe { std::slice::from_raw_parts_mut(buf, capacity) };
        // SAFETY: non-null, live handle per the ABI contract.
        unsafe { instance_ref(embed) }.read_output(buf)
    });
    match result {
        Ok(count) => {
            // SAFETY: writing the caller's optional out-param.
            unsafe { write_error_out(error_out, ok_result()) };
            count as i64
        }
        Err(error) => {
            let flattened = flatten(embed, Err(error));
            // SAFETY: writing the caller's optional out-param.
            unsafe { write_error_out(error_out, flattened) };
            -1
        }
    }
}

/// Applies a new window size by publishing the grid through the size env
/// (embed patch 0006's geometry seam); the client's resize poll re-renders.
#[no_mangle]
pub extern "C" fn herdr_embed_set_winsize(
    embed: *mut herdr_embed,
    cols: u16,
    rows: u16,
) -> HerdrEmbedResult {
    let result = catch(|| {
        if embed.is_null() {
            return Err(invalid("embed pointer is null"));
        }
        if cols == 0 || rows == 0 {
            return Err(invalid("cols and rows must each be 1..=65535"));
        }
        // SAFETY: non-null, live handle per the ABI contract.
        unsafe { instance_ref(embed) }.set_winsize(cols, rows)
    });
    flatten(embed, result)
}

/// True while the client thread is running (before stop and before the
/// client's own exit).
#[no_mangle]
pub extern "C" fn herdr_embed_is_running(embed: *mut herdr_embed) -> bool {
    catch(|| {
        if embed.is_null() {
            return Ok(false);
        }
        // SAFETY: non-null, live handle per the ABI contract.
        Ok(unsafe { instance_ref(embed) }.is_running())
    })
    .unwrap_or(false)
}

/// Borrowed NUL-terminated socket path (owned by the instance until its next
/// call or stop).
#[no_mangle]
pub extern "C" fn herdr_embed_socket_path(embed: *mut herdr_embed) -> *const c_char {
    catch(|| {
        if embed.is_null() {
            return Ok(ptr::null());
        }
        // SAFETY: non-null, live handle per the ABI contract; the CString
        // lives as long as the instance.
        Ok(unsafe { instance_ref(embed) }.socket_path_c().as_ptr())
    })
    .unwrap_or(ptr::null())
}

/// Stops the client, joins its thread, restores the host stdio, closes every
/// socket/pipe fd, and frees the handle — which is dead afterwards. On
/// HERDR_EMBED_CODE_STOP_TIMEOUT the instance stays alive and stop may be
/// retried with the same handle.
#[no_mangle]
pub extern "C" fn herdr_embed_stop(embed: *mut herdr_embed) -> HerdrEmbedResult {
    let result = catch(|| {
        if embed.is_null() {
            return Err(invalid("embed pointer is null"));
        }
        // SAFETY: non-null, live handle per the ABI contract; borrowed here
        // so the allocation survives a retryable timeout.
        let instance = unsafe { instance_ref(embed) };
        instance.stop()
    });
    match result {
        Ok(()) => {
            // SAFETY: taking back the unique allocation from
            // herdr_embed_start; the caller gives up the handle for good.
            drop(unsafe { Box::from_raw(embed.cast::<EmbedInstance>()) });
            ok_result()
        }
        Err(error) => flatten(embed, Err(error)),
    }
}
