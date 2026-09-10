//! Read-only ABI surface: snapshot/surface JSON accessors, phase and
//! buffer diagnostics, byte-buffer release, and telemetry. Split from
//! `abi.rs` (lifecycle and I/O entries) so each module stays under the
//! reviewed size ceiling.
use crate::abi::state_ref;
use crate::client::HerdrClient;
use crate::support::{invalid, leak_bytes, ok_result, store_detail, write_error_out};
use crate::{catch, herdr_bytes, herdr_client, track_free, FfiError, HerdrResult};
use std::ffi::c_char;
use std::ptr;

/// Returns the latest accepted shell snapshot as stable JSON
/// (`shell.snapshot.v1` carrier), or empty when none has been accepted.
#[no_mangle]
pub extern "C" fn herdr_client_snapshot(
    client: *mut herdr_client,
    error_out: *mut HerdrResult,
) -> herdr_bytes {
    json_accessor(client, error_out, HerdrClient::snapshot_json)
}

/// Returns the latest committed pane surface as stable JSON, or empty.
#[no_mangle]
pub extern "C" fn herdr_client_surface(
    client: *mut herdr_client,
    error_out: *mut HerdrResult,
) -> herdr_bytes {
    json_accessor(client, error_out, HerdrClient::surface_json)
}

fn json_accessor(
    client: *mut herdr_client,
    error_out: *mut HerdrResult,
    access: fn(&HerdrClient) -> Result<Option<String>, FfiError>,
) -> herdr_bytes {
    let result = catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        // SAFETY: non-null handle; shared borrow for the call's duration.
        Ok(access(unsafe { state_ref(client) })?)
    });
    match result {
        Ok(json) => {
            write_error_out(error_out, ok_result());
            leak_bytes(json.unwrap_or_default().into_bytes())
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

/// HERDR_PHASE_* value of the client.
#[no_mangle]
pub extern "C" fn herdr_client_phase(client: *mut herdr_client) -> u32 {
    catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        // SAFETY: non-null handle; shared borrow for the call's duration.
        Ok(unsafe { state_ref(client) }.phase())
    })
    .unwrap_or(u32::MAX)
}

/// Bytes buffered awaiting a complete inbound frame (diagnostic bound check).
#[no_mangle]
pub extern "C" fn herdr_client_pending_inbound(client: *mut herdr_client) -> u64 {
    catch(|| {
        if client.is_null() {
            return Err(invalid("client pointer is null"));
        }
        // SAFETY: non-null handle; shared borrow for the call's duration.
        Ok(unsafe { state_ref(client) }.pending_inbound())
    })
    .unwrap_or(u64::MAX)
}

/// Frees a buffer returned by this ABI exactly once; `{null, 0}` is a no-op.
#[no_mangle]
pub extern "C" fn herdr_bytes_free(bytes: herdr_bytes) {
    if bytes.data.is_null() {
        return;
    }
    track_free();
    // SAFETY: reconstructs exactly the Box<[u8]> produced by leak_bytes —
    // same pointer, same length, called exactly once per buffer (ABI contract).
    let boxed: Box<[u8]> =
        unsafe { Box::from_raw(std::slice::from_raw_parts_mut(bytes.data, bytes.len)) };
    drop(boxed);
}

/// Live allocations currently owned by C callers (diagnostics; zero expected).
#[no_mangle]
pub extern "C" fn herdr_debug_live_allocations() -> u64 {
    crate::debug_live_allocations()
}

/// Library provenance, e.g. "0.9.0" (static, never freed).
#[no_mangle]
pub extern "C" fn herdr_core_version() -> *const c_char {
    ptr::addr_of!(VERSION_BYTES[0]).cast()
}

static VERSION_BYTES: [u8; 6] = *b"0.9.0\0";
