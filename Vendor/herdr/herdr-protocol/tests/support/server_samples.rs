use herdr_protocol::{endpoint::*, *};

pub fn samples() -> serde_json::Result<Vec<ServerMessage>> {
    let snapshot: ClientShellSnapshot =
        serde_json::from_str(include_str!("../fixtures/endpoint-snapshot-v1.json"))?;
    let welcome = EndpointServerWelcome::compatible(vec!["client_shell.surface.set".into()]);
    let cell = CellData {
        symbol: "e\u{301}".into(),
        fg: 0x02_ff8000,
        bg: 0x01_00002a,
        modifier: 0x3001,
        skip: false,
        hyperlink: Some(0),
    };
    let surface = PaneSurfaceFrame {
        boot_id: "boot".into(),
        projection_revision: 3,
        surface_revision: 7,
        frame: FrameData {
            width: 1,
            height: 1,
            cells: vec![cell.clone()],
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 6,
            }),
            hyperlinks: vec!["https://example.com".into()],
            graphics: vec![],
        },
        panes: vec![],
        splits: vec![],
        popup: None,
        graphics: SurfaceGraphicsScene::default(),
    };
    Ok(vec![
        ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            encoding: RenderEncoding::SemanticFrame,
            error: None,
        },
        ServerMessage::Terminal(TerminalFrame {
            seq: 256,
            width: 80,
            height: 24,
            full: true,
            bytes: vec![27, 91, 72],
        }),
        ServerMessage::Graphics {
            bytes: vec![0, 255],
        },
        ServerMessage::ServerShutdown {
            reason: Some("done".into()),
        },
        ServerMessage::Notify {
            kind: NotifyKind::SystemToast,
            message: "ready".into(),
            body: Some("body".into()),
        },
        ServerMessage::Clipboard {
            data: "aGVsbG8=".into(),
        },
        ServerMessage::WindowTitle {
            title: Some("terminal".into()),
        },
        ServerMessage::ReloadSoundConfig,
        ServerMessage::MouseCapture {
            enabled: true,
            sgr_pixels: true,
        },
        ServerMessage::TerminalBell { count: 2 },
        ServerMessage::GraphicsFile {
            path: "/remote/image.rgba".into(),
            expected_len: 4,
            image_id: 2,
            transfer_id: 300,
            leading: vec![27],
            control: "a=t".into(),
            surface_asset: None,
        },
        ServerMessage::GraphicsTransmissionRetired {
            transfer_id: 300,
            image_id: 2,
        },
        ServerMessage::ClientShellSnapshot(Box::new(snapshot.clone())),
        ServerMessage::PaneSurface(surface),
        ServerMessage::SemanticNotification(SemanticNotification {
            kind: SemanticNotificationKind::NeedsAttention,
            title: "attention".into(),
            body: Some("body".into()),
            sound: Some(SemanticNotificationSound::Request),
            agent: Some("reviewer".into()),
            workspace_id: Some("w1".into()),
            tab_id: Some("w1:t1".into()),
            pane_id: Some("w1:p1".into()),
            position: Some(ToastHerdrPosition::TopRight),
        }),
        ServerMessage::ClientShellError {
            message: "unavailable".into(),
        },
        ServerMessage::DirectTerminalKeyboardProtocol {
            flags: 3,
            modify_other_keys_level: 2,
        },
        ServerMessage::ClientShellKeyboardReportAll { enabled: true },
        ServerMessage::ClientShellEndpointResponseChunk {
            boot_id: "boot".into(),
            request_id: "r1".into(),
            final_chunk: true,
            data: b"{}".to_vec(),
        },
        ServerMessage::PaneSurfacePatch(PaneSurfacePatch {
            boot_id: "boot".into(),
            projection_revision: 3,
            base_surface_revision: 7,
            surface_revision: 8,
            rows: vec![PaneSurfacePatchRow {
                x: 0,
                y: 0,
                cells: vec![cell],
            }],
            panes: vec![],
            cursor: None,
        }),
        ServerMessage::EndpointControl {
            kind: ENDPOINT_WELCOME_KIND.into(),
            data: serde_json::to_string(&welcome)?,
        },
        snapshot_message(&snapshot)?,
    ])
}
