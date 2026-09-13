//! Headless harness: keystrokes fed through `herdr_embed_write_input` reach
//! the real client and the default detach keybinding (ctrl+b q) detaches it
//! cleanly. Own process — see headless_frame.rs for the one-client-per-process
//! rationale.
mod common;

use common::{
    detail_text, fd_state, redirect_client_env, serial, start_instance, tap_output,
};
use herdr_ios_embed::{herdr_embed_is_running, herdr_embed_write_input, HERDR_EMBED_CODE_OK};
use std::time::Duration;

const FRAME_TIMEOUT: Duration = Duration::from_secs(20);
const EXIT_TIMEOUT: Duration = Duration::from_secs(10);

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

#[test]
fn keystrokes_reach_the_client_and_prefix_q_detaches_cleanly() {
    let _serial = serial();
    common::install_panic_log();
    let server = common::ServerFixture::start("detach");
    let _env = redirect_client_env("detach");

    let mut embed = start_instance(&server.client_socket.to_string_lossy(), 80, 24);
    let tap = tap_output(embed.handle());
    let (acc, ready) = tap.wait_until(
        &|acc| acc.windows(8).any(|w| w == b"\x1b[?1049h") && count_sgr(acc) >= 5,
        FRAME_TIMEOUT,
    );
    assert!(ready, "no TUI frame before input ({} bytes)", acc.len());

    // ctrl+b (prefix) then q (detach) — the client's default keybindings,
    // written as separate single-byte reads like a real keyboard would.
    let result = unsafe { herdr_embed_write_input(embed.handle(), b"\x02".as_ptr(), 1) };
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    std::thread::sleep(Duration::from_millis(120));
    let result = unsafe { herdr_embed_write_input(embed.handle(), b"q".as_ptr(), 1) };
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));

    let exited = common::poll_until(EXIT_TIMEOUT, &|| {
        !herdr_embed_is_running(embed.handle())
    });
    if !exited {
        let dump_dir = common::repo_root()
            .join(".build-artifacts/herdr-embed-test")
            .join(format!("detach-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dump_dir);
        let _ = std::fs::write(dump_dir.join("client-output.bin"), &acc);
    }
    assert!(exited, "client did not detach on prefix+q — input did not reach it");

    // Drain the tail: the client restores the terminal on exit.
    let (tail, _) = tap.wait_until(&|_| false, Duration::from_secs(3));
    let mut all = acc;
    all.extend_from_slice(&tail);
    assert!(
        all.windows(8).any(|w| w == b"\x1b[?1049l"),
        "client did not leave the alternate screen on detach"
    );

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (_, ttys) = fd_state();
    assert!(ttys.is_empty(), "pty fds leaked: {ttys:?}");
}
