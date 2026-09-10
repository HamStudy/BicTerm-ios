// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (1736:1980). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
use serde::Serialize;
#[test]
fn client_hello_roundtrip() {
    let msg = ClientMessage::TerminalHello {
        version: PROTOCOL_VERSION,
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
fn client_shell_hello_roundtrip() {
    let msg = ClientMessage::ClientShellHello {
        version: PROTOCOL_VERSION,
        cell_width_px: 8,
        cell_height_px: 16,
        surface_size: ClientSurfaceSize { cols: 80, rows: 29 },
        pixel_mouse: true,
        direct_graphics: false,
        endpoint_keybindings: true,
        mouse_capture: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn endpoint_control_roundtrip() {
    let msg = ClientMessage::EndpointControl {
        kind: "endpoint.hello.v1".into(),
        data: r#"{"generation":1}"#.into(),
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
    assert_eq!(
        bincode::serde::encode_to_vec(
            ClientMessage::EndpointControl {
                kind: String::new(),
                data: String::new(),
            },
            bincode::config::standard(),
        )
        .unwrap(),
        [20, 0, 0]
    );
}

#[test]
fn client_shell_resize_roundtrip() {
    let msg = ClientMessage::ClientShellResize {
        cell_width_px: 8,
        cell_height_px: 16,
        surface_size: ClientSurfaceSize { cols: 74, rows: 29 },
        pixel_mouse: true,
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
    assert_eq!(
        encoded_sha256(&msg),
        "676d6376202750e72c45ff511e256b6154d3d20c0ee088d3792fa3a69d9704b9"
    );
}

#[test]
fn client_input_roundtrip() {
    let msg = ClientMessage::Input {
        data: vec![0x1b, 0x5b, 0x41], // ESC [ A (up arrow)
    };
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ClientMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}

#[test]
fn client_message_wire_tags_reflect_current_order() {
    fn tag(msg: &ClientMessage) -> u8 {
        *bincode::serde::encode_to_vec(msg, bincode::config::standard())
            .unwrap()
            .first()
            .expect("encoded client message should include enum tag")
    }

    assert_eq!(
        tag(&ClientMessage::TerminalHello {
            version: PROTOCOL_VERSION,
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: false,
        }),
        0
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellHello {
            version: PROTOCOL_VERSION,
            cell_width_px: 8,
            cell_height_px: 16,
            surface_size: ClientSurfaceSize { cols: 80, rows: 29 },
            pixel_mouse: false,
            direct_graphics: false,
            endpoint_keybindings: false,
            mouse_capture: false,
        }),
        11
    );
    assert_eq!(tag(&ClientMessage::Input { data: Vec::new() }), 1);
    assert_eq!(
        tag(&ClientMessage::ClipboardImage {
            target: ClientClipboardImageTarget::DirectTerminal,
            extension: "png".to_owned(),
            data: Vec::new(),
        }),
        2
    );
    assert_eq!(
        tag(&ClientMessage::Resize {
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: false,
        }),
        3
    );
    assert_eq!(tag(&ClientMessage::Detach), 4);
    assert_eq!(
        tag(&ClientMessage::AttachTerminal {
            terminal_id: "term".to_owned(),
            takeover: false,
        }),
        5
    );
    assert_eq!(
        tag(&ClientMessage::AttachScroll {
            source: AttachScrollSource::Wheel,
            direction: AttachScrollDirection::Up,
            lines: 1,
            column: None,
            row: None,
            modifiers: 0,
        }),
        6
    );
    assert_eq!(
        tag(&ClientMessage::ObserveTerminal {
            target: "w1:p1".to_owned(),
        }),
        7
    );
    assert_eq!(
        tag(&ClientMessage::ControlTerminal {
            target: "w1:p1".to_owned(),
            takeover: false,
        }),
        8
    );
    assert_eq!(
        tag(&ClientMessage::GraphicsTransmissionResult {
            transfer_id: 1,
            image_id: 2,
            success: true,
        }),
        9
    );
    assert_eq!(
        tag(&ClientMessage::GraphicsTransmissionStarted {
            transfer_id: 1,
            image_id: 2,
        }),
        10
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellResize {
            cell_width_px: 8,
            cell_height_px: 16,
            surface_size: ClientSurfaceSize { cols: 80, rows: 29 },
            pixel_mouse: false,
        }),
        12
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellPaneInput {
            pane_id: "pane".into(),
            events: Vec::new(),
        }),
        13
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellPopupInput {
            terminal_id: "popup".into(),
            events: Vec::new(),
        }),
        14
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellEndpointRequest {
            boot_id: "boot".into(),
            request: "{}".into(),
        }),
        15
    );
    assert_eq!(
        tag(&ClientMessage::AttachMouse {
            kind: ClientMouseKind::Down(ClientMouseButton::Left),
            position: ClientMousePosition::Cell { column: 10, row: 5 },
            geometry: None,
            modifiers: 0,
            lines: 1,
        }),
        16
    );
    assert_eq!(
        tag(&ClientMessage::ClientShellHostTheme {
            update: ClientHostThemeUpdate::Appearance(ClientHostAppearance::Dark),
        }),
        17
    );
    assert_eq!(tag(&ClientMessage::ClientShellFocus { focused: true }), 18);
    assert_eq!(
        tag(&ClientMessage::ClientShellMouseCapture { enabled: true }),
        19
    );
    assert_eq!(
        tag(&ClientMessage::EndpointControl {
            kind: String::new(),
            data: String::new(),
        }),
        20
    );
}

fn encoded_sha256(value: &impl Serialize) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(bincode::serde::encode_to_vec(value, bincode::config::standard()).unwrap())
    )
}
