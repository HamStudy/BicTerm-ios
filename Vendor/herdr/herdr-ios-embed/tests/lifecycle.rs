//! Shim + instance lifecycle tests: no herdr server needed. The client is
//! pointed at a missing socket, so `run_client` fails fast after its startup
//! sequence — enough to exercise the full start/exit/stop cycle, stdio
//! save/restore, and the env-published grid seam without a live TUI.
mod common;

use common::{detail_text, fd_state, poll_until, redirect_client_env, serial, start_instance};
use herdr_ios_embed::{
    herdr_embed_is_running, herdr_embed_read_output, herdr_embed_set_winsize, HerdrEmbedResult,
    HERDR_EMBED_CODE_IO, HERDR_EMBED_CODE_OK,
};
use std::ffi::CString;
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

    // Drain: buffered output first, then either the clean 0 (stopped/exited)
    // or the typed IO error carrying the recorded exit detail — a missing
    // socket fails the client's startup dial, and read_output surfaces that
    // exit error once the drain empties (clean exits keep the bare EOF).
    let mut buf = [0u8; 4096];
    let mut exit_detail = None;
    for _ in 0..64 {
        let mut error = HerdrEmbedResult {
            code: HERDR_EMBED_CODE_OK,
            detail: std::ptr::null(),
        };
        let n = herdr_embed_read_output(embed.handle(), buf.as_mut_ptr(), buf.len(), &mut error);
        if n == 0 {
            break;
        }
        if n < 0 {
            assert_eq!(
                error.code, HERDR_EMBED_CODE_IO,
                "unexpected read_output error code"
            );
            exit_detail = Some(detail_text(error.detail));
            break;
        }
    }
    let exit_detail = exit_detail.expect("missing-socket exit must surface its detail");
    assert!(
        exit_detail.contains("failed to connect to server"),
        "unexpected exit detail: {exit_detail}"
    );

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (count_after, ttys_after) = fd_state();
    assert!(ttys_after.is_empty(), "tty fds leaked: {ttys_after:?}");
    assert_eq!(count_after, count_before, "fd count changed across the cycle");
}

#[test]
fn set_winsize_publishes_the_grid_through_the_size_env() {
    let _serial = serial();
    common::install_panic_log();
    let _env = redirect_client_env("size-env");

    let saved = (
        std::env::var("HERDR_EMBED_COLS").ok(),
        std::env::var("HERDR_EMBED_ROWS").ok(),
    );

    // A listener that never answers holds the client in its 5s local
    // handshake wait, so set_winsize runs against a LIVE instance (after the
    // client's self-exit cleanup the host socket is closed and set_winsize
    // would correctly refuse with NOT_RUNNING).
    let dir = common::test_dir("size-env");
    let socket_path = dir.join("listener.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket_path)
        .expect("bind the handshake listener");

    let mut embed = start_instance(&socket_path.to_string_lossy(), 80, 24);
    assert!(
        herdr_embed_is_running(embed.handle()),
        "client did not stay up against the silent listener"
    );

    // The start config's grid is published before the client boots (the
    // boot gate waits for the thread's env re-assert), so it is observable
    // the moment start returns.
    assert_eq!(
        std::env::var("HERDR_EMBED_COLS").as_deref(),
        Ok("80"),
        "start did not publish the initial grid"
    );
    assert_eq!(std::env::var("HERDR_EMBED_ROWS").as_deref(), Ok("24"));

    let result = herdr_embed_set_winsize(embed.handle(), 100, 30);
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    assert_eq!(
        std::env::var("HERDR_EMBED_COLS").as_deref(),
        Ok("100"),
        "set_winsize did not publish the new grid"
    );
    assert_eq!(std::env::var("HERDR_EMBED_ROWS").as_deref(), Ok("30"));

    match saved {
        (Some(cols), Some(rows)) => {
            std::env::set_var("HERDR_EMBED_COLS", cols);
            std::env::set_var("HERDR_EMBED_ROWS", rows);
        }
        _ => {
            std::env::remove_var("HERDR_EMBED_COLS");
            std::env::remove_var("HERDR_EMBED_ROWS");
        }
    }

    let exited = poll_until(Duration::from_secs(10), &|| !herdr_embed_is_running(embed.handle()));
    assert!(exited, "client did not exit after the handshake timeout");
    drop(listener);
    let _ = std::fs::remove_file(&socket_path);

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (_, ttys) = fd_state();
    assert!(ttys.is_empty(), "tty fds leaked: {ttys:?}");
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
