//! `#[no_mangle]` C surface. Every entry point is wrapped in [`crate::catch`]
//! so no panic unwinds into C, and every pointer crossing is documented with a
//! SAFETY argument. Error details are borrowed: client calls overwrite the
//! client-owned string; client-less calls (create, null handles) use a
//! thread-local overwritten by the next such call on that thread.
use crate::client::HerdrClient;
use crate::input_map::InputPayload;
use crate::support::{finish, invalid, leak_bytes, ok_result, store_detail, write_error_out};
use crate::{
    catch, herdr_bytes, herdr_client, herdr_client_config, herdr_input, track_allocation,
    track_free, FfiError, HerdrResult, HERDR_CODE_INVALID_ARGUMENT, HERDR_INPUT_KEY,
    HERDR_INPUT_PASTE, HERDR_INPUT_TEXT_COMMIT,
};
use std::ffi::{c_char, CStr};
use std::ptr;

/// Casts the opaque handle back to its Rust payload pointer.
///
/// # Safety in ABI context (not a Rust-safe API)
/// The handle must be non-null, originate from `herdr_client_create`, not yet
/// be destroyed, and be confined to one serial executor (documented ABI rule);
/// callers must never hold the returned reference across another ABI call.
unsafe fn state_ptr(client: *mut herdr_client) -> *mut HerdrClient {
    client.cast()
}

/// # Safety in ABI context
/// Same contract as `state_ptr`; returns a shared reference valid for the
/// duration of the current ABI call only.
pub(crate) unsafe fn state_ref<'a>(client: *mut herdr_client) -> &'a HerdrClient {
    &*state_ptr(client)
}

/// # Safety in ABI context
/// Same contract as `state_ptr`; returns an exclusive reference valid for the
/// duration of the current ABI call only.
unsafe fn state_mut<'a>(client: *mut herdr_client) -> &'a mut HerdrClient {
    &mut *state_ptr(client)
}

/// Creates an endpoint client and queues the generation-1 hello frame; drain
/// it with `herdr_client_drain_outbound`. Returns null on failure with the
/// structured reason in `error_out` (optional).
#[no_mangle]
pub extern "C" fn herdr_client_create(
    config: *const herdr_client_config,
    error_out: *mut HerdrResult,
) -> *mut herdr_client {
    let result = catch(|| {
        if config.is_null() {
            return Err(invalid("config pointer is null"));
        }
        // SAFETY: caller provides a readable config for the call's duration.
        let config = unsafe { &*config };
        crate::factory::create(config)
    });
    match result {
        Ok(inner) => {
            write_error_out(error_out, ok_result());
            track_allocation();
            // SAFETY: fresh allocation handed to C as the opaque handle; the
            // only way back is herdr_client_destroy's cast below.
            Box::into_raw(Box::new(inner)).cast::<herdr_client>()
        }
        Err(error) => {
            write_error_out(error_out, store_detail(ptr::null_mut(), error));
            ptr::null_mut()
        }
    }
}

/// Releases the client and every buffer it still owns. The handle must not be
/// used afterwards; byte buffers previously handed out stay caller-owned.
#[no_mangle]
pub extern "C" fn herdr_client_destroy(client: *mut herdr_client) {
    if client.is_null() {
        return;
    }
    let result = catch(|| {
        // SAFETY: taking back the unique HerdrClient allocation from
        // herdr_client_create; the caller gives up the handle for this call.
        track_free();
        drop(unsafe { Box::from_raw(state_ptr(client)) });
        Ok(())
    });
    if let Err(error) = result {
        // A drop-time panic cannot cross the boundary; surface it only through
        // the same thread-local channel and keep the process alive.
        let _ = store_detail(ptr::null_mut(), error);
    }
}

/// Feeds opaque transport bytes (stdout of the remote bridge) to the decoder.
#[no_mangle]
pub extern "C" fn herdr_client_receive(
    client: *mut herdr_client,
    bytes: *const u8,
    len: usize,
) -> HerdrResult {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        if len == 0 {
            return Ok(());
        }
        if bytes.is_null() {
            return Err(invalid("bytes pointer is null with a non-zero length"));
        }
        // SAFETY: caller provides `len` readable bytes for the call; the slice
        // is copied into the client buffer and never retained.
        let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.receive(bytes)?)
    });
    finish(client, result)
}

/// Sends one semantic input event to an explicit pane target from the latest
/// snapshot. Routing and lease validation happen in the Rust core.
#[no_mangle]
pub extern "C" fn herdr_client_send_input(
    client: *mut herdr_client,
    input: *const herdr_input,
) -> HerdrResult {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        if input.is_null() {
            return Err(invalid("input pointer is null"));
        }
        // SAFETY: caller provides a readable input struct for the call.
        let input = unsafe { &*input };
        let payload = match input.kind {
            HERDR_INPUT_TEXT_COMMIT => InputPayload::TextCommit(cstr(input.text, "text")?),
            HERDR_INPUT_PASTE => InputPayload::Paste(cstr(input.text, "text")?),
            HERDR_INPUT_KEY => InputPayload::Key {
                key: crate::herdr_key {
                    code: input.key.code,
                    codepoint: input.key.codepoint,
                    modifiers: input.key.modifiers,
                    kind: input.key.kind,
                    repeat_count: input.key.repeat_count,
                    shifted_codepoint: input.key.shifted_codepoint,
                },
            },
            other => {
                return Err(FfiError::new(
                    HERDR_CODE_INVALID_ARGUMENT,
                    format!("unknown input kind {other}"),
                ))
            }
        };
        let pane_id = cstr(input.pane_id, "pane_id")?;
        if pane_id.is_empty() {
            return Err(invalid("pane_id is required"));
        }
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.send_input(&pane_id, payload)?)
    });
    finish(client, result)
}

/// Reads one C string as UTF-8; `name` names the field in diagnostics.
fn cstr(pointer: *const c_char, name: &'static str) -> Result<String, FfiError> {
    if pointer.is_null() {
        return Err(FfiError::new(
            HERDR_CODE_INVALID_ARGUMENT,
            format!("{name} pointer is null"),
        ));
    }
    // SAFETY: caller provides a NUL-terminated string for the call's duration.
    let bytes = unsafe { CStr::from_ptr(pointer) }.to_bytes();
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| FfiError::new(HERDR_CODE_INVALID_ARGUMENT, format!("{name} is not UTF-8")))
}

/// Pops one complete outbound frame (opaque, length-prefixed) for the
/// transport write; an empty result means the queue is drained.
#[no_mangle]
pub extern "C" fn herdr_client_drain_outbound(
    client: *mut herdr_client,
    error_out: *mut HerdrResult,
) -> herdr_bytes {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.drain_outbound()?)
    });
    match result {
        Ok(frame) => {
            write_error_out(error_out, ok_result());
            leak_bytes(frame.unwrap_or_default())
        }
        Err(error) => {
            let detail = store_detail(client, error);
            write_error_out(error_out, detail);
            herdr_bytes {
                data: ptr::null_mut(),
                len: 0,
            }
        }
    }
}

/// Drains the one-shot clipboard slot holding the decoded bytes of the most
/// recent OSC 52 server clipboard frame; empty when none arrived since the
/// previous take. The returned buffer is caller-owned; free it with
/// `herdr_bytes_free` exactly once.
#[no_mangle]
pub extern "C" fn herdr_client_take_clipboard(
    client: *mut herdr_client,
    error_out: *mut HerdrResult,
) -> herdr_bytes {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.take_clipboard())
    });
    match result {
        Ok(bytes) => {
            write_error_out(error_out, ok_result());
            leak_bytes(bytes.unwrap_or_default())
        }
        Err(error) => {
            let detail = store_detail(client, error);
            write_error_out(error_out, detail);
            herdr_bytes {
                data: ptr::null_mut(),
                len: 0,
            }
        }
    }
}

/// Sends one local-clipboard image (raw bytes plus a file extension without
/// a leading dot) to the given pane for remote paste bridging. Guarded like
/// semantic input: requires the Online phase and an unfrozen input lane.
#[no_mangle]
pub extern "C" fn herdr_client_send_clipboard_image(
    client: *mut herdr_client,
    pane_id: *const c_char,
    extension: *const c_char,
    data: *const u8,
    len: usize,
) -> HerdrResult {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        let pane_id = cstr(pane_id, "pane_id")?;
        if pane_id.is_empty() {
            return Err(invalid("pane_id is required"));
        }
        let extension = cstr(extension, "extension")?;
        if extension.is_empty() {
            return Err(invalid("extension is required"));
        }
        if len == 0 {
            return Err(invalid("data length must be non-zero"));
        }
        if data.is_null() {
            return Err(invalid("data pointer is null with a non-zero length"));
        }
        // SAFETY: caller provides `len` readable bytes for the call; the
        // slice is copied into the queued message and never retained.
        let data = unsafe { std::slice::from_raw_parts(data, len) };
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.send_clipboard_image(&pane_id, &extension, data)?)
    });
    finish(client, result)
}

/// Resizes the logical surface geometry (each dimension 1..=65535). While an
/// activation transaction is in flight the resize routes through it so
/// pending surface evidence is invalidated coherently; otherwise the resize
/// frame is queued directly to the endpoint transport.
#[no_mangle]
pub extern "C" fn herdr_client_resize(
    client: *mut herdr_client,
    cols: u32,
    rows: u32,
) -> HerdrResult {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        if cols == 0 || rows == 0 || cols > u16::MAX as u32 || rows > u16::MAX as u32 {
            return Err(invalid("cols and rows must each be 1..=65535"));
        }
        // SAFETY: non-null, serially confined handle (ABI invariant).
        Ok(unsafe { state_mut(client) }.resize(cols, rows)?)
    });
    finish(client, result)
}
