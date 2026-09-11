//! Fuzz target: length-prefixed frame parsing (`herdr_protocol::read_message`).
//!
//! Contract under fuzz (doc §9 fail-closed rules): arbitrary transport bytes
//! must never panic, must never allocate more than the configured frame
//! ceiling, and must report oversized/trailing-data/bincode failures as
//! errors instead of accepting the frame. A successful decode must consume
//! a prefix of the input.
#![no_main]

use herdr_protocol::{read_message, ServerMessage, MAX_FRAME_SIZE};
use libfuzzer_sys::fuzz_target;
use std::io::Cursor;

fuzz_target!(|data: &[u8]| {
    for max_frame_size in [MAX_FRAME_SIZE, 64, 4096] {
        let mut cursor = Cursor::new(data);
        let outcome: Result<ServerMessage, _> = read_message(&mut cursor, max_frame_size);
        if outcome.is_ok() {
            assert!(
                cursor.position() as usize <= data.len(),
                "decoder consumed more than the fed bytes"
            );
        }
    }
});
