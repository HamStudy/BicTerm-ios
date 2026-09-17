//! Headless harness: the REAL herdr client renders its TUI into the host
//! socket through the embed FFI (plan task 3 acceptance line).
//!
//! One test per file on purpose: each integration test file is its own
//! process, and the embedded client's SIGTERM quit path (its ctrlc handler)
//! is only installable by the first client in a process — later installs
//! fail with "already registered". A dedicated process makes stop()
//! deterministic.
mod common;

use common::{
    detail_text, fd_state, redirect_client_env, serial, start_instance, tap_output,
};
use herdr_ios_embed::{herdr_embed_is_running, herdr_embed_socket_path, HERDR_EMBED_CODE_OK};
use std::ffi::CStr;
use std::time::Duration;

const FRAME_TIMEOUT: Duration = Duration::from_secs(20);

fn count_sgr(bytes: &[u8]) -> usize {
    let mut count = 0usize;
    let mut index = 0usize;
    while index + 1 < bytes.len() {
        if bytes[index] == 0x1b && bytes[index + 1] == b'[' {
            if let Some(end) = bytes[index + 2..].iter().position(|b| *b == b'm') {
                count += 1;
                index += end + 3;
                continue;
            }
        }
        index += 1;
    }
    count
}

fn printable_count(bytes: &[u8]) -> usize {
    bytes.iter().filter(|b| b.is_ascii_graphic() || **b == b' ').count()
}

#[test]
fn embedded_client_renders_its_tui_into_the_host_socket() {
    let _serial = serial();
    common::install_panic_log();
    let server = common::ServerFixture::start("frame");
    let _env = redirect_client_env("frame");

    let (_, ttys_before) = fd_state();
    assert!(ttys_before.is_empty());

    let mut embed = start_instance(&server.client_socket.to_string_lossy(), 80, 24);
    let tap = tap_output(embed.handle());
    let (acc, ready) = tap.wait_until(
        &|acc| {
            acc.windows(8).any(|w| w == b"\x1b[?1049h")
                && count_sgr(acc) >= 5
                && printable_count(acc) >= 50
        },
        FRAME_TIMEOUT,
    );
    // Failure diagnostics land repo-local: the panic message itself would be
    // swallowed by the redirected stdio while the instance runs.
    let dump_dir = common::repo_root()
        .join(".build-artifacts/herdr-embed-test")
        .join(format!("frame-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dump_dir);
    let _ = std::fs::write(dump_dir.join("client-output.bin"), &acc);
    assert!(
        ready,
        "no recognizable TUI frame reached the host socket ({} bytes so far)",
        acc.len()
    );
    assert!(
        acc.windows(8).any(|w| w == b"\x1b[?1049h"),
        "client never entered the alternate screen"
    );
    assert!(herdr_embed_is_running(embed.handle()));

    let path = unsafe { CStr::from_ptr(herdr_embed_socket_path(embed.handle())) };
    assert!(
        path.to_bytes().ends_with(b"herdr-client.sock"),
        "socket_path returned {path:?}"
    );

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    // The shim's own hygiene: every socket fd must be gone. (The client
    // itself may retain one process-global fd per cycle — its tokio runtime
    // shuts down on a 100ms budget — so an exact whole-process count is not
    // assertable here; the shim-level lifecycle test covers exact counts.)
    let (_, ttys_after) = fd_state();
    assert!(ttys_after.is_empty(), "tty fds leaked: {ttys_after:?}");
}
