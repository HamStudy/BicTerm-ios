//! Borrowed-error and byte-buffer plumbing shared by the C entry points.
use crate::client::HerdrClient;
use crate::{
    herdr_bytes, herdr_client, track_allocation, FfiError, HerdrResult,
    HERDR_CODE_INVALID_ARGUMENT, HERDR_CODE_OK,
};
use std::cell::RefCell;
use std::ffi::CString;
use std::ptr;

thread_local! {
    /// Last error detail produced without a client handle; bounded to one
    /// allocation per thread and overwritten by the next such call.
    static HANDLELESS_DETAIL: RefCell<CString> = RefCell::new(CString::new("").expect("static"));
}

pub(crate) fn ok_result() -> HerdrResult {
    HerdrResult {
        code: HERDR_CODE_OK,
        detail: ptr::null(),
    }
}

pub(crate) fn invalid(detail: &'static str) -> FfiError {
    FfiError::new(HERDR_CODE_INVALID_ARGUMENT, detail)
}

/// Flattens the guard outcome into a `HerdrResult`, parking non-OK details in
/// the client (or the thread-local slot for null handles).
pub(crate) fn finish(client: *mut herdr_client, outcome: Result<(), FfiError>) -> HerdrResult {
    match outcome {
        Ok(()) => ok_result(),
        Err(error) => store_detail(client, error),
    }
}

/// Stores `error` where its detail outlives the return: in the client when one
/// exists, otherwise in the thread-local handle-less slot.
pub(crate) fn store_detail(client: *mut herdr_client, error: FfiError) -> HerdrResult {
    let code = error.code;
    if !client.is_null() {
        // SAFETY: non-null per check; the handle stays alive for the duration
        // of this call (caller contract) and is serially confined.
        let inner = unsafe { &mut *client.cast::<HerdrClient>() };
        inner.last_detail = error.detail;
        return HerdrResult {
            code,
            detail: inner.last_detail.as_ptr(),
        };
    }
    HANDLELESS_DETAIL.with(|slot| {
        let mut slot = slot.borrow_mut();
        *slot = error.detail;
        HerdrResult {
            code,
            detail: slot.as_ptr(),
        }
    })
}

// SAFETY: writing a plain C struct through a caller-provided out-pointer; the
// pointer is non-null and properly aligned per the C calling convention.
pub(crate) fn write_error_out(error_out: *mut HerdrResult, result: HerdrResult) {
    if !error_out.is_null() {
        unsafe { ptr::write_unaligned(error_out, result) };
    }
}

/// Moves a byte buffer to C ownership; every returned buffer must come back
/// through `herdr_bytes_free` exactly once.
pub(crate) fn leak_bytes(bytes: Vec<u8>) -> herdr_bytes {
    let len = bytes.len();
    if len == 0 {
        return herdr_bytes {
            data: ptr::null_mut(),
            len: 0,
        };
    }
    track_allocation();
    let boxed = bytes.into_boxed_slice();
    herdr_bytes {
        // SAFETY: handing the allocation to C; reclaimed only by reconstructing
        // the identical Box<[u8]> in herdr_bytes_free.
        data: ptr::from_mut(Box::leak(boxed)).cast(),
        len,
    }
}
