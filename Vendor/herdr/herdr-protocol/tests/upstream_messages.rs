// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (2114:2327). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
use serde::Serialize;
#[test]
fn client_shell_focus_roundtrip() {
    let message = ClientMessage::ClientShellFocus { focused: false };
    let encoded = bincode::serde::encode_to_vec(&message, bincode::config::standard())
        .expect("encode client shell focus");
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard())
            .expect("decode client shell focus");
    assert_eq!(decoded, message);
}

#[test]
fn client_shell_mouse_capture_roundtrip() {
    let message = ClientMessage::ClientShellMouseCapture { enabled: false };
    let encoded = bincode::serde::encode_to_vec(&message, bincode::config::standard())
        .expect("encode client shell mouse capture");
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard())
            .expect("decode client shell mouse capture");
    assert_eq!(decoded, message);
}

#[test]
fn client_shell_host_theme_roundtrip() {
    let message = ClientMessage::ClientShellHostTheme {
        update: ClientHostThemeUpdate::PaletteColors(vec![(
            4,
            ClientHostColor {
                r: 10,
                g: 20,
                b: 30,
            },
        )]),
    };
    let encoded = bincode::serde::encode_to_vec(&message, bincode::config::standard())
        .expect("encode host theme update");
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard())
            .expect("decode host theme update");
    assert_eq!(decoded, message);
}

#[test]
fn client_shell_endpoint_messages_roundtrip() {
    let request = ClientMessage::ClientShellEndpointRequest {
        boot_id: "boot-a".into(),
        request: r#"{"id":"request-a","method":"session.snapshot","params":{}}"#.into(),
    };
    let encoded = bincode::serde::encode_to_vec(&request, bincode::config::standard())
        .expect("encode endpoint request");
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard())
            .expect("decode endpoint request");
    assert_eq!(decoded, request);
    assert_eq!(
        encoded_sha256(&request),
        "de5693585a01f6b0d5ee07c51b6ddf79ee9f67dbf183255822d31f35210f5ffb"
    );

    let response = ServerMessage::ClientShellEndpointResponseChunk {
        boot_id: "boot-a".into(),
        request_id: "request-a".into(),
        final_chunk: true,
        data: br#"{"id":"request-a","result":{"type":"ok"}}"#.to_vec(),
    };
    let encoded = bincode::serde::encode_to_vec(&response, bincode::config::standard())
        .expect("encode endpoint response");
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard())
            .expect("decode endpoint response");
    assert_eq!(decoded, response);
    assert_eq!(
        encoded_sha256(&response),
        "bc14dbb5263d3097fe6d3e70a4b6d71aa9c2fa4ae3206d692a7182512bffdd1d"
    );
}

#[test]
fn client_clipboard_image_roundtrip() {
    let msg = ClientMessage::ClipboardImage {
        target: ClientClipboardImageTarget::Pane("w1:p1".into()),
        extension: "png".to_owned(),
        data: vec![0x89, b'P', b'N', b'G'],
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
    assert_eq!(
        encoded_sha256(&msg),
        "1c02110be0671faf318b3f4d8f507748d5a0a98cd474832669c5290d97ef19ab"
    );
}

#[test]
fn client_input_large_multilingual_payload_roundtrip() {
    let text = "你好，今天我们测试一段比较长的语音输入。こんにちは。안녕하세요.🙂".repeat(1024);
    assert!(text.len() > 64 * 1024);
    assert!(text.len() < MAX_FRAME_SIZE);
    let msg = ClientMessage::Input {
        data: text.as_bytes().to_vec(),
    };

    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, consumed): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();

    assert_eq!(consumed, encoded.len());
    assert_eq!(decoded, msg);
}

#[test]
fn client_resize_roundtrip() {
    let msg = ClientMessage::Resize {
        cols: 80,
        rows: 24,
        cell_width_px: 8,
        cell_height_px: 16,
        pixel_mouse: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_detach_roundtrip() {
    let msg = ClientMessage::Detach;
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_attach_terminal_roundtrip() {
    let msg = ClientMessage::AttachTerminal {
        terminal_id: "term_123".to_owned(),
        takeover: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_observe_terminal_roundtrip() {
    let msg = ClientMessage::ObserveTerminal {
        target: "w1:p1".to_owned(),
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_control_terminal_roundtrip() {
    let msg = ClientMessage::ControlTerminal {
        target: "w1:p1".to_owned(),
        takeover: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_attach_scroll_roundtrip() {
    let msg = ClientMessage::AttachScroll {
        source: AttachScrollSource::Wheel,
        direction: AttachScrollDirection::Up,
        lines: 3,
        column: Some(12),
        row: Some(7),
        modifiers: 4,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

// ---- Round-trip: ServerMessage ----

#[test]
fn server_welcome_roundtrip() {
    let msg = ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        encoding: RenderEncoding::SemanticFrame,
        error: None,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn server_welcome_with_error_roundtrip() {
    let msg = ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        encoding: RenderEncoding::SemanticFrame,
        error: Some("incompatible version".to_owned()),
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

fn encoded_sha256(value: &impl Serialize) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(bincode::serde::encode_to_vec(value, bincode::config::standard()).unwrap())
    )
}
