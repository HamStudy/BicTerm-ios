// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (2876:2891 2951:3191 3471:3500). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
use std::io::{self, Read};
    #[test]
    fn framing_small_message_roundtrip() {
        let msg = ClientMessage::TerminalHello {
            version: PROTOCOL_VERSION,
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: false,
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &msg).unwrap();
        let decoded: ClientMessage = read_message(&mut buf.as_slice(), MAX_FRAME_SIZE).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn framing_multiple_messages_sequential() {
        // Write 100+ messages of varying types and read them back.
        let mut buf = Vec::new();
        let mut expected = Vec::new();

        for i in 0..150u32 {
            let msg = match i % 5 {
                0 => ClientMessage::TerminalHello {
                    version: PROTOCOL_VERSION,
                    cols: (80 + (i % 40) as u16),
                    rows: (24 + (i % 20) as u16),
                    cell_width_px: 8,
                    cell_height_px: 16,
                    pixel_mouse: i % 2 == 0,
                },
                1 => ClientMessage::Input {
                    data: vec![(i % 256) as u8; (i as usize % 50) + 1],
                },
                2 => ClientMessage::ClipboardImage {
                    target: ClientClipboardImageTarget::DirectTerminal,
                    extension: "png".to_owned(),
                    data: vec![0x89, b'P', b'N', b'G', (i % 256) as u8],
                },
                3 => ClientMessage::Resize {
                    cols: (100 + (i % 30) as u16),
                    rows: (30 + (i % 10) as u16),
                    cell_width_px: 8,
                    cell_height_px: 16,
                    pixel_mouse: i % 2 == 0,
                },
                4 => ClientMessage::Detach,
                _ => unreachable!(),
            };
            write_message(&mut buf, &msg).unwrap();
            expected.push(msg);
        }

        let mut cursor = buf.as_slice();
        for expected_msg in &expected {
            let decoded: ClientMessage = read_message(&mut cursor, MAX_FRAME_SIZE).unwrap();
            assert_eq!(*expected_msg, decoded);
        }
    }

    #[test]
    fn framing_oversized_rejected_without_panic() {
        // Craft a frame with a huge length prefix (4 GB claim).
        let mut buf: Vec<u8> = (u32::MAX).to_le_bytes().to_vec();
        // Add a few garbage bytes after the length prefix.
        buf.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);

        let result: Result<ClientMessage, FramingError> =
            read_message(&mut buf.as_slice(), MAX_FRAME_SIZE);
        match result {
            Err(FramingError::Oversized { claimed, max }) => {
                assert_eq!(claimed, u32::MAX as usize);
                assert_eq!(max, MAX_FRAME_SIZE);
            }
            other => panic!("expected Oversized error, got: {other:?}"),
        }
    }

    #[test]
    fn framing_malformed_payload_rejected_without_panic() {
        // Valid length prefix pointing to garbage data.
        let payload = vec![0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02];
        let mut buf = (payload.len() as u32).to_le_bytes().to_vec();
        buf.extend_from_slice(&payload);

        let result: Result<ClientMessage, FramingError> =
            read_message(&mut buf.as_slice(), MAX_FRAME_SIZE);
        assert!(result.is_err(), "malformed payload should be rejected");
        match result {
            Err(FramingError::Bincode(_)) => {} // expected
            other => panic!("expected Bincode error, got: {other:?}"),
        }
    }

    #[test]
    fn framing_truncated_stream_returns_unexpected_eof() {
        // Write a length prefix claiming 100 bytes, but only provide 4.
        let mut buf: Vec<u8> = 100u32.to_le_bytes().to_vec();
        buf.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD]);

        let result: Result<ClientMessage, FramingError> =
            read_message(&mut buf.as_slice(), MAX_FRAME_SIZE);
        match result {
            Err(FramingError::UnexpectedEof) => {}
            other => panic!("expected UnexpectedEof, got: {other:?}"),
        }
    }

    #[test]
    fn framing_zero_length_message() {
        // A 1-byte message (smallest possible valid bincode payload).
        // Actually, let's test with the smallest real message: Detach.
        let msg = ClientMessage::Detach;
        let mut buf = Vec::new();
        write_message(&mut buf, &msg).unwrap();

        // Verify the length prefix is correct
        let len = u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize;
        assert_eq!(
            len,
            buf.len() - 4,
            "length prefix should match payload size"
        );

        let decoded: ClientMessage = read_message(&mut buf.as_slice(), MAX_FRAME_SIZE).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn framing_partial_read_reassembly() {
        // Simulate partial reads by using a reader that yields small chunks.
        let msg = ClientMessage::Input {
            data: vec![42; 500], // 500-byte input payload
        };
        let mut full_buf = Vec::new();
        write_message(&mut full_buf, &msg).unwrap();

        // Wrap in a chunked reader that only yields 7 bytes at a time.
        let mut chunked = ChunkedReader::new(full_buf, 7);
        let decoded: ClientMessage = read_message(&mut chunked, MAX_FRAME_SIZE).unwrap();
        assert_eq!(msg, decoded);
    }

    // ---- Version negotiation ----

    #[test]
    fn version_compatible() {
        assert_eq!(
            check_client_version(PROTOCOL_VERSION),
            VersionCheck::Compatible
        );
    }

    #[test]
    fn version_older_client_rejected() {
        let result = check_client_version(PROTOCOL_VERSION - 1);
        assert!(matches!(result, VersionCheck::Incompatible(_)));
        if let VersionCheck::Incompatible(msg) = result {
            assert!(msg.contains("older"), "error should mention older version");
        }
    }

    #[test]
    fn version_newer_client_rejected() {
        let result = check_client_version(PROTOCOL_VERSION + 1);
        assert!(matches!(result, VersionCheck::Incompatible(_)));
        if let VersionCheck::Incompatible(msg) = result {
            assert!(msg.contains("newer"), "error should mention newer version");
        }
    }

    // ---- Pre-persistence client rejection ----

    #[test]
    fn prepersistence_version_zero_rejected() {
        let result = check_client_version(0);
        match result {
            VersionCheck::Incompatible(msg) => {
                assert!(
                    msg.contains("pre-persistence"),
                    "error should mention pre-persistence: {msg}"
                );
            }
            _ => panic!("version 0 should be rejected as incompatible"),
        }
    }

    #[test]
    fn prepersistence_version_zero_welcome_has_error() {
        // Simulating what the server would send to a v0 client.
        let check = check_client_version(0);
        let response = match check {
            VersionCheck::Compatible => ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                encoding: RenderEncoding::SemanticFrame,
                error: None,
            },
            VersionCheck::Incompatible(reason) => ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                encoding: RenderEncoding::SemanticFrame,
                error: Some(reason),
            },
        };

        match response {
            ServerMessage::Welcome { error: Some(_), .. } => {}
            other => panic!("expected Welcome with error, got: {other:?}"),
        }
    }

    // ---- Malformed/oversized input ----

    #[test]
    fn oversized_frame_does_not_panic() {
        // Claim 4GB payload — should return Oversized error, not panic.
        let mut buf: Vec<u8> = 0xFFC00000u32.to_le_bytes().to_vec(); // ~4 GB claim
        buf.extend_from_slice(&[0; 8]);

        let result: Result<ClientMessage, FramingError> =
            read_message(&mut buf.as_slice(), MAX_FRAME_SIZE);
        assert!(result.is_err());
        // Did not panic — test passing is proof.
    }

    #[test]
    fn malformed_frame_does_not_panic() {
        // Random garbage bytes after a valid-ish length prefix.
        let garbage: Vec<u8> = (0..200).map(|i| (i ^ 0xAA) as u8).collect();
        let mut buf = (garbage.len() as u32).to_le_bytes().to_vec();
        buf.extend_from_slice(&garbage);

        let result: Result<ClientMessage, FramingError> =
            read_message(&mut buf.as_slice(), MAX_FRAME_SIZE);
        assert!(result.is_err());
        // Did not panic.
    }

    #[test]
    fn oversized_input_rejected_custom_max() {
        // Verify a custom (small) max_frame_size is enforced.
        let msg = ClientMessage::Input {
            data: vec![0x41; 1000],
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &msg).unwrap();

        let result: Result<ClientMessage, FramingError> = read_message(&mut buf.as_slice(), 64);
        // The actual bincode payload for 1000 bytes of input will be > 64 bytes.
        assert!(
            matches!(result, Err(FramingError::Oversized { .. })),
            "expected Oversized with small max_frame_size"
        );
    }

    // ---- FrameData ↔ ratatui Buffer conversion ----

    /// A `Read` wrapper that yields at most `chunk_size` bytes per `read()` call,
    /// simulating partial reads on a real socket.
    struct ChunkedReader {
        data: Vec<u8>,
        pos: usize,
        chunk_size: usize,
    }

    impl ChunkedReader {
        fn new(data: Vec<u8>, chunk_size: usize) -> Self {
            Self {
                data,
                pos: 0,
                chunk_size,
            }
        }
    }

    impl Read for ChunkedReader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.pos >= self.data.len() {
                return Ok(0);
            }
            let remaining = self.data.len() - self.pos;
            let to_read = buf.len().min(remaining).min(self.chunk_size);
            buf[..to_read].copy_from_slice(&self.data[self.pos..self.pos + to_read]);
            self.pos += to_read;
            Ok(to_read)
        }
    }
