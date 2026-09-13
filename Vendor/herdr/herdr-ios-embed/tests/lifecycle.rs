//! Shim + instance lifecycle tests: no herdr server needed. The client is
//! pointed at a missing socket, so `run_client` fails fast after its startup
//! sequence — enough to exercise the full start/exit/stop cycle, stdio
//! save/restore, and SIGWINCH delivery without a live TUI.
mod common;

use common::{detail_text, fd_state, poll_until, redirect_client_env, serial, start_instance};
use herdr_ios_embed::{
    herdr_embed_is_running, herdr_embed_read_output, herdr_embed_set_winsize, HerdrEmbedResult,
    HERDR_EMBED_CODE_OK,
};
use std::ffi::CString;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

fn missing_socket(tag: &str) -> String {
    common::test_dir(tag)
        .join("absent")
        .join("herdr-client.sock")
        .to_string_lossy()
        .into_owned()
}

#[test]
fn instance_exits_against_a_missing_socket_and_stop_restores_fd_hygiene() {
    let _serial = serial();
    common::install_panic_log();
    let _env = redirect_client_env("lifecycle");
    // Warm-up cycle: absorbs one-time process-global lazily-initialized fds
    // (tracing subscriber file handle, runtime pools) so the second cycle can
    // assert exact fd-count stability.
    {
        let mut embed = start_instance(&missing_socket("lifecycle-warmup"), 80, 24);
        let exited = poll_until(Duration::from_secs(10), &|| !herdr_embed_is_running(embed.handle()));
        assert!(exited, "client did not exit against a missing socket");
        let result = embed.stop();
        assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    }
    let (count_before, _) = fd_state();

    let mut embed = start_instance(&missing_socket("lifecycle"), 80, 24);
    assert!(herdr_embed_is_running(embed.handle()));
    let exited = poll_until(Duration::from_secs(10), &|| !herdr_embed_is_running(embed.handle()));
    assert!(exited, "client did not exit against a missing socket");

    // Drain: the final read must be the clean 0 (stopped/exited), never an
    // error. (A failed connect produces no flushed output: the client's only
    // stdout writes are newline-less control sequences that stay buffered.)
    let mut buf = [0u8; 4096];
    for _ in 0..64 {
        let n = herdr_embed_read_output(
            embed.handle(),
            buf.as_mut_ptr(),
            buf.len(),
            std::ptr::null_mut(),
        );
        assert!(n >= 0, "read_output errored after exit");
        if n == 0 {
            break;
        }
    }

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (count_after, ttys_after) = fd_state();
    assert!(ttys_after.is_empty(), "pty fds leaked: {ttys_after:?}");
    assert_eq!(count_after, count_before, "fd count changed across the cycle");
}

#[test]
fn set_winsize_updates_the_pty_and_delivers_sigwinch() {
    let _serial = serial();
    common::install_panic_log();
    let _env = redirect_client_env("sigwinch");

    static DELIVERED: AtomicBool = AtomicBool::new(false);
    extern "C" fn record_sigwinch(_signal: std::ffi::c_int) {
        DELIVERED.store(true, Ordering::Release);
    }
    // SAFETY: installing a flag-setting handler for the delivery proof; the
    // embedded client is not running here (missing socket), so nothing
    // competes for the process-wide sigaction slot.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = record_sigwinch as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }

    let mut embed = start_instance(&missing_socket("sigwinch"), 80, 24);
    let exited = poll_until(Duration::from_secs(10), &|| !herdr_embed_is_running(embed.handle()));
    assert!(exited, "client did not exit against a missing socket");

    let result = herdr_embed_set_winsize(embed.handle(), 100, 30);
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let delivered = poll_until(Duration::from_secs(5), &|| DELIVERED.load(Ordering::Acquire));
    assert!(delivered, "SIGWINCH was not delivered after set_winsize");

    // Restore the default disposition so later tests in this binary are not
    // affected by the test handler.
    // SAFETY: resetting SIGWINCH to SIG_DFL after the delivery proof.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = libc::SIG_DFL as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (_, ttys) = fd_state();
    assert!(ttys.is_empty(), "pty fds leaked: {ttys:?}");
}

#[test]
fn start_rejects_bad_arguments_without_touching_global_state() {
    let _serial = serial();
    common::install_panic_log();
    let (count_before, _) = fd_state();
    let mut error = HerdrEmbedResult {
        code: -1,
        detail: std::ptr::null(),
    };
    let config = herdr_ios_embed::herdr_embed_config {
        socket_path: std::ptr::null(),
        cols: 80,
        rows: 24,
        detach_input: std::ptr::null(),
        detach_len: 0,
    };
    let embed = herdr_ios_embed::herdr_embed_start(&config, (&raw mut error).cast());
    assert!(embed.is_null());
    assert_eq!(error.code, herdr_ios_embed::HERDR_EMBED_CODE_INVALID_ARGUMENT);
    let socket = CString::new("/no/such/path.sock").expect("static");
    let config = herdr_ios_embed::herdr_embed_config {
        socket_path: socket.as_ptr(),
        cols: 0,
        rows: 24,
        detach_input: std::ptr::null(),
        detach_len: 0,
    };
    let embed = herdr_ios_embed::herdr_embed_start(&config, (&raw mut error).cast());
    assert!(embed.is_null());
    assert_eq!(error.code, herdr_ios_embed::HERDR_EMBED_CODE_INVALID_ARGUMENT);
    let (count_after, ttys_after) = fd_state();
    assert!(ttys_after.is_empty());
    assert_eq!(count_after, count_before);
}
