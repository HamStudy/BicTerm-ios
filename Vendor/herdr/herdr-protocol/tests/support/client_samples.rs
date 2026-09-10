use herdr_protocol::{endpoint::*, *};

pub fn samples() -> serde_json::Result<Vec<ClientMessage>> {
    let size = ClientSurfaceSize { cols: 80, rows: 24 };
    let hello: EndpointClientHello =
        serde_json::from_str(include_str!("../fixtures/endpoint-hello-v1.json"))?;
    let events = vec![
        ClientPaneInputEvent::Key {
            code: ClientKeyCode::Char('界'),
            modifiers: 3,
            kind: ClientKeyKind::Release,
            repeat_count: 2,
            shifted_codepoint: Some(u32::from('Z')),
            generated_text: Some("界".into()),
            tracks_release: true,
            physical_key_id: Some(42),
            windows_record: Some(WindowsKeyRecord {
                key_down: false,
                repeat_count: 2,
                virtual_key_code: 65,
                virtual_scan_code: 30,
                unicode: 65,
                control_key_state: 8,
            }),
        },
        ClientPaneInputEvent::TextCommit("e\u{301} 日本語".into()),
        ClientPaneInputEvent::Mouse {
            kind: ClientMouseKind::Drag(ClientMouseButton::Middle),
            position: ClientMousePosition::Pixels {
                x: 25,
                y: 30,
                column: 2,
                row: 1,
            },
            geometry: Some(ClientMouseGeometry {
                cols: 80,
                rows: 24,
                width_px: 640,
                height_px: 384,
            }),
            modifiers: 2,
            lines: 3,
        },
        ClientPaneInputEvent::Paste("one\ntwo\r\n".into()),
    ];
    Ok(vec![
        ClientMessage::TerminalHello {
            version: PROTOCOL_VERSION,
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: false,
        },
        ClientMessage::Input {
            data: vec![0, 255, 10, 13],
        },
        ClientMessage::ClipboardImage {
            target: ClientClipboardImageTarget::DirectTerminal,
            extension: "png".into(),
            data: vec![137, 80, 78, 71],
        },
        ClientMessage::Resize {
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: true,
        },
        ClientMessage::Detach,
        ClientMessage::AttachTerminal {
            terminal_id: "term".into(),
            takeover: true,
        },
        ClientMessage::AttachScroll {
            source: AttachScrollSource::Wheel,
            direction: AttachScrollDirection::Up,
            lines: 3,
            column: Some(2),
            row: Some(1),
            modifiers: 1,
        },
        ClientMessage::ObserveTerminal {
            target: "w1:p1".into(),
        },
        ClientMessage::ControlTerminal {
            target: "w1:p1".into(),
            takeover: true,
        },
        ClientMessage::GraphicsTransmissionResult {
            transfer_id: 300,
            image_id: 2,
            success: true,
        },
        ClientMessage::GraphicsTransmissionStarted {
            transfer_id: 300,
            image_id: 2,
        },
        ClientMessage::ClientShellHello {
            version: PROTOCOL_VERSION,
            cell_width_px: 8,
            cell_height_px: 16,
            surface_size: size,
            pixel_mouse: true,
            direct_graphics: false,
            endpoint_keybindings: false,
            mouse_capture: true,
        },
        ClientMessage::ClientShellResize {
            cell_width_px: 8,
            cell_height_px: 16,
            surface_size: size,
            pixel_mouse: true,
        },
        ClientMessage::ClientShellPaneInput {
            pane_id: "w1:p1".into(),
            events: events.clone(),
        },
        ClientMessage::ClientShellPopupInput {
            terminal_id: "popup".into(),
            events,
        },
        ClientMessage::ClientShellEndpointRequest {
            boot_id: "boot".into(),
            request: "{\"id\":\"r1\",\"method\":\"pane.focus\",\"params\":{\"pane_id\":\"w1:p1\"}}"
                .into(),
        },
        ClientMessage::AttachMouse {
            kind: ClientMouseKind::ScrollRight,
            position: ClientMousePosition::Cell { column: 2, row: 1 },
            geometry: None,
            modifiers: 4,
            lines: 2,
        },
        ClientMessage::ClientShellHostTheme {
            update: ClientHostThemeUpdate::PaletteColors(vec![(
                1,
                ClientHostColor {
                    r: 255,
                    g: 128,
                    b: 64,
                },
            )]),
        },
        ClientMessage::ClientShellFocus { focused: true },
        ClientMessage::ClientShellMouseCapture { enabled: false },
        ClientMessage::EndpointControl {
            kind: ENDPOINT_HELLO_KIND.into(),
            data: serde_json::to_string(&hello)?,
        },
    ])
}
