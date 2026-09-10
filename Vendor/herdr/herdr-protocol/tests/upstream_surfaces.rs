// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (2423:2610). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
use serde::Serialize;
    #[test]
    fn pane_surface_patch_roundtrip() {
        let msg = ServerMessage::PaneSurfacePatch(PaneSurfacePatch {
            boot_id: "boot-1".into(),
            projection_revision: 3,
            base_surface_revision: 7,
            surface_revision: 8,
            rows: vec![PaneSurfacePatchRow {
                x: 2,
                y: 4,
                cells: vec![CellData {
                    symbol: "x".into(),
                    fg: 1,
                    bg: 2,
                    modifier: 3,
                    skip: false,
                    hyperlink: None,
                }],
            }],
            panes: Vec::new(),
            cursor: Some(CursorState {
                x: 2,
                y: 4,
                visible: true,
                shape: 2,
            }),
        });
        let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
        let (decoded, _): (ServerMessage, _) =
            bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
        assert_eq!(decoded, msg);
        assert_eq!(
            encoded_sha256(&msg),
            "0814b99a1dc6eaf7918424aa416c066509cbfb73b72344a809c27cde78cb6dbd"
        );
    }

    #[test]
    fn client_shell_graphics_payload_codec_is_frozen() {
        let key = SurfaceGraphicsAssetKey {
            source: SurfaceGraphicsSource::Terminal {
                target: SurfaceGraphicsTarget::Pane {
                    pane_id: "w1:p1".into(),
                },
                image_id: 7,
            },
            image_width: 2,
            image_height: 1,
            format: SurfaceGraphicsFormat::Rgba,
            data_len: 8,
            data_fingerprint: 42,
        };
        let message = ServerMessage::PaneSurface(PaneSurfaceFrame {
            boot_id: "boot-1".into(),
            projection_revision: 2,
            surface_revision: 3,
            frame: FrameData {
                cells: Vec::new(),
                width: 0,
                height: 0,
                cursor: None,
                hyperlinks: Vec::new(),
                graphics: Vec::new(),
            },
            panes: Vec::new(),
            splits: Vec::new(),
            popup: None,
            graphics: SurfaceGraphicsScene {
                assets: vec![SurfaceGraphicsAsset {
                    key: key.clone(),
                    data: vec![255, 0, 0, 255, 0, 255, 0, 255],
                }],
                placements: vec![SurfaceGraphicsPlacement {
                    asset: key,
                    logical_placement_id: 9,
                    x: 1,
                    y: 2,
                    cols: 2,
                    rows: 1,
                    source_x: 0,
                    source_y: 0,
                    source_width: 2,
                    source_height: 1,
                    x_offset: 0,
                    y_offset: 0,
                    z: -1,
                    scrollback_offset: 0,
                }],
                retained_assets: Vec::new(),
            },
        });

        assert_eq!(
            encoded_sha256(&message),
            "49c4efec0f1456c8ca4112ddf6ead1ab75d0224007576c2ccc18c3fca55a69f0"
        );
    }

    #[test]
    fn server_endpoint_control_tag_is_frozen() {
        let message = ServerMessage::EndpointControl {
            kind: "endpoint.welcome.v1".into(),
            data: r#"{"generation":1}"#.into(),
        };
        let encoded = bincode::serde::encode_to_vec(&message, bincode::config::standard()).unwrap();
        assert_eq!(encoded.first(), Some(&20));
        assert_eq!(
            bincode::serde::encode_to_vec(
                ServerMessage::EndpointControl {
                    kind: String::new(),
                    data: String::new(),
                },
                bincode::config::standard(),
            )
            .unwrap(),
            [20, 0, 0]
        );
        let (decoded, _): (ServerMessage, _) =
            bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
        assert_eq!(decoded, message);
    }

    #[test]
    fn client_shell_server_message_tags_are_frozen() {
        fn tag(message: &ServerMessage) -> u8 {
            *bincode::serde::encode_to_vec(message, bincode::config::standard())
                .unwrap()
                .first()
                .expect("encoded server message should include enum tag")
        }

        let empty_frame = || PaneSurfaceFrame {
            boot_id: "boot".into(),
            projection_revision: 1,
            surface_revision: 1,
            frame: FrameData {
                cells: Vec::new(),
                width: 0,
                height: 0,
                cursor: None,
                hyperlinks: Vec::new(),
                graphics: Vec::new(),
            },
            panes: Vec::new(),
            splits: Vec::new(),
            popup: None,
            graphics: SurfaceGraphicsScene::default(),
        };
        assert_eq!(tag(&ServerMessage::PaneSurface(empty_frame())), 13);
        assert_eq!(
            tag(&ServerMessage::ClientShellError {
                message: String::new(),
            }),
            15
        );
        assert_eq!(
            tag(&ServerMessage::ClientShellKeyboardReportAll { enabled: false }),
            17
        );
        assert_eq!(
            tag(&ServerMessage::ClientShellEndpointResponseChunk {
                boot_id: String::new(),
                request_id: String::new(),
                final_chunk: true,
                data: Vec::new(),
            }),
            18
        );
        assert_eq!(
            tag(&ServerMessage::PaneSurfacePatch(PaneSurfacePatch {
                boot_id: String::new(),
                projection_revision: 0,
                base_surface_revision: 0,
                surface_revision: 0,
                rows: Vec::new(),
                panes: Vec::new(),
                cursor: None,
            })),
            19
        );
        assert_eq!(
            tag(&ServerMessage::EndpointControl {
                kind: String::new(),
                data: String::new(),
            }),
            20
        );
    }

fn encoded_sha256(value: &impl Serialize) -> String { use sha2::{Digest, Sha256}; format!("{:x}", Sha256::digest(bincode::serde::encode_to_vec(value, bincode::config::standard()).unwrap())) }
