//! Fuzz target: bincode payload decode of every frozen wire enum
//! (`ServerMessage`, `ClientMessage`) plus lossless re-encode of whatever
//! decodes. The decoder must never panic on arbitrary bytes, must never
//! claim to have consumed more bytes than it was given, and any value it
//! accepts must re-encode without panicking (the round-trip invariant the
//! frozen-frame conformance tests pin on golden vectors).
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let config = herdr_protocol::framing_decode_config();
    let server: Result<(herdr_protocol::ServerMessage, usize), _> =
        bincode::serde::decode_from_slice(data, config);
    if let Ok((message, consumed)) = server {
        assert!(consumed <= data.len(), "server decode over-consumed input");
        let _ = bincode::serde::encode_to_vec(&message, config);
    }
    let client: Result<(herdr_protocol::ClientMessage, usize), _> =
        bincode::serde::decode_from_slice(data, config);
    if let Ok((message, consumed)) = client {
        assert!(consumed <= data.len(), "client decode over-consumed input");
        let _ = bincode::serde::encode_to_vec(&message, config);
    }
});
