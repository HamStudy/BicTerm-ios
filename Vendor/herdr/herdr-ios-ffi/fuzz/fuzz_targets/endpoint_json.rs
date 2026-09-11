//! Fuzz target: the stable JSON carriers and the handshake admission gate.
//!
//! Arbitrary bytes reach (as lossy UTF-8) every decode the endpoint path
//! performs on server-controlled text: the `EndpointServerWelcome` and
//! `ClientShellSnapshot` carriers, and `PendingHandshake::receive` — the
//! gate that must reject wrong generation, wrong codecs, malformed JSON,
//! error-carrying welcomes, and missing capabilities without panicking.
#![no_main]

use herdr_client_core::handshake::PendingHandshake;
use herdr_protocol::endpoint::{
    EndpointClientHello, EndpointServerWelcome, BLOB_CODEC_V1, ENDPOINT_PROTOCOL_GENERATION,
    ENDPOINT_WELCOME_KIND, INPUT_CODEC_V1, SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
};
use herdr_protocol::{ClientShellSnapshot, ClientSurfaceSize, ServerMessage};
use libfuzzer_sys::fuzz_target;
use std::time::Instant;

fn conservative_hello() -> EndpointClientHello {
    EndpointClientHello {
        generation: ENDPOINT_PROTOCOL_GENERATION,
        cell_width_px: 8,
        cell_height_px: 16,
        surface_size: ClientSurfaceSize { cols: 80, rows: 24 },
        pixel_mouse: false,
        direct_graphics: false,
        endpoint_keybindings: false,
        mouse_capture: false,
        surface_active: true,
        snapshot_codecs: vec![SNAPSHOT_CODEC_V1.to_owned()],
        surface_codecs: vec![SURFACE_CODEC_V1.to_owned()],
        input_codecs: vec![INPUT_CODEC_V1.to_owned()],
        blob_codecs: vec![BLOB_CODEC_V1.to_owned()],
    }
}

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let _ = serde_json::from_str::<EndpointServerWelcome>(&text);
    let _ = serde_json::from_str::<ClientShellSnapshot>(&text);

    if let Ok((handshake, _)) = PendingHandshake::begin(&conservative_hello(), Instant::now()) {
        let _ = handshake.receive(
            ServerMessage::EndpointControl {
                kind: ENDPOINT_WELCOME_KIND.to_owned(),
                data: text.into_owned(),
            },
            Instant::now(),
        );
    }
});
