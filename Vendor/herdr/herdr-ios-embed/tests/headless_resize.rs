//! Headless harness: `herdr_embed_set_winsize` applies the new pty geometry
//! and the real client re-renders at the new size. Own process — see
//! headless_frame.rs for the one-client-per-process rationale.
mod common;

use common::{
    detail_text, fd_state, redirect_client_env, serial, start_instance, tap_output,
};
use herdr_ios_embed::{herdr_embed_set_winsize, HERDR_EMBED_CODE_OK};
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

#[test]
fn resize_updates_the_pty_and_the_client_redraws() {
    let _serial = serial();
    common::install_panic_log();
    let server = common::ServerFixture::start("resize");
    let _env = redirect_client_env("resize");

    let mut embed = start_instance(&server.client_socket.to_string_lossy(), 80, 24);
    let tap = tap_output(embed.handle());
    let (acc, ready) = tap.wait_until(
        &|acc| acc.windows(8).any(|w| w == b"\x1b[?1049h") && count_sgr(acc) >= 5,
        FRAME_TIMEOUT,
    );
    assert!(ready, "no TUI frame before resize ({} bytes)", acc.len());
    let mark = acc.len();

    let result = unsafe { herdr_embed_set_winsize(embed.handle(), 120, 40) };
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));

    // The client's resize watcher re-reads the pty geometry and re-renders;
    // a full redraw at the new size is a substantial byte burst.
    let (acc, _) = tap.wait_until(
        &|acc| acc.len() >= mark + 256,
        Duration::from_secs(10),
    );
    assert!(
        acc.len() >= mark + 256,
        "client produced no redraw after the winsize change ({} bytes total)",
        acc.len()
    );

    let result = embed.stop();
    assert_eq!(result.code, HERDR_EMBED_CODE_OK, "{}", detail_text(result.detail));
    let (_, ttys) = fd_state();
    assert!(ttys.is_empty(), "pty fds leaked: {ttys:?}");
}
