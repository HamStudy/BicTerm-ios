// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (2695:2875). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
use serde::Serialize;
#[test]
fn server_shutdown_roundtrip() {
    let msg = ServerMessage::ServerShutdown {
        reason: Some("updating".to_owned()),
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn semantic_notification_roundtrip() {
    let msg = ServerMessage::SemanticNotification(SemanticNotification {
        kind: SemanticNotificationKind::NeedsAttention,
        title: "codex needs attention".into(),
        body: Some("repo · 1".into()),
        sound: Some(SemanticNotificationSound::Request),
        agent: Some("codex".into()),
        workspace_id: Some("w1".into()),
        tab_id: Some("w1:t1".into()),
        pane_id: Some("w1:p1".into()),
        position: Some(crate::ToastHerdrPosition::TopRight),
    });
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn server_notify_roundtrip() {
    for kind in [
        NotifyKind::Sound,
        NotifyKind::Toast,
        NotifyKind::SystemToast,
    ] {
        let msg = ServerMessage::Notify {
            kind,
            message: "agent done".to_owned(),
            body: None,
        };
        let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
        let (decoded, _): (ServerMessage, _) =
            bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
        assert_eq!(msg, decoded);
    }
}

#[test]
fn server_clipboard_roundtrip() {
    let msg = ServerMessage::Clipboard {
        data: "dGVzdA==".to_owned(), // base64 "test"
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn server_window_title_roundtrip() {
    for title in [Some("herdr api".to_owned()), None] {
        let msg = ServerMessage::WindowTitle { title };
        let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
        let (decoded, _): (ServerMessage, _) =
            bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
        assert_eq!(msg, decoded);
    }
}

#[test]
fn server_graphics_roundtrip() {
    let msg = ServerMessage::Graphics {
        bytes: b"\x1b_Ga=d,d=A,q=2;\x1b\\".to_vec(),
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
    assert_eq!(
        encoded_sha256(&msg),
        "28a420f92e0e05e6760a8c140baf307c360c6d1b1aa68027481b324f87e22c44"
    );
}

#[test]
fn server_terminal_frame_roundtrip() {
    let msg = ServerMessage::Terminal(TerminalFrame {
        seq: 7,
        width: 120,
        height: 40,
        full: false,
        bytes: b"\x1b[1;1Hhello".to_vec(),
    });
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn server_reload_sound_config_roundtrip() {
    let msg = ServerMessage::ReloadSoundConfig;
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn server_mouse_capture_roundtrip() {
    let msg = ServerMessage::MouseCapture {
        enabled: true,
        sgr_pixels: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_shell_keyboard_report_all_roundtrip() {
    let msg = ServerMessage::ClientShellKeyboardReportAll { enabled: true };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn direct_terminal_keyboard_mode_roundtrip() {
    let msg = ServerMessage::DirectTerminalKeyboardProtocol {
        flags: 15,
        modify_other_keys_level: 1,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn direct_graphics_messages_roundtrip() {
    let client = ClientMessage::GraphicsTransmissionResult {
        transfer_id: 7,
        image_id: 42,
        success: false,
    };
    let encoded = bincode::serde::encode_to_vec(&client, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(client, decoded);

    let server = ServerMessage::GraphicsFile {
        path: "/run/user/1000/herdr/source/frame".into(),
        expected_len: 4,
        image_id: 42,
        transfer_id: 7,
        leading: b"\x1b[2;3H".to_vec(),
        control: "a=T,f=32,i=42,q=0".into(),
        surface_asset: None,
    };
    let encoded = bincode::serde::encode_to_vec(&server, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(server, decoded);
}

#[test]
fn server_terminal_bell_roundtrip() {
    let msg = ServerMessage::TerminalBell { count: 3 };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

// ---- Framing ----

fn encoded_sha256(value: &impl Serialize) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(bincode::serde::encode_to_vec(value, bincode::config::standard()).unwrap())
    )
}
