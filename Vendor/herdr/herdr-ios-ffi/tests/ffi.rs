//! Host-side FFI tests against the committed golden frames. These exercise
//! the exact extern "C" surface the xcframework ships.
use herdr_ios_ffi::*;
use herdr_protocol::{
    write_message, CellData, ClientMessage, FrameData, PaneSurfaceFrame, PaneSurfacePane,
    ServerMessage, SurfaceGraphicsScene, SurfaceRect,
};
use std::ffi::CString;
use std::ptr;
use std::sync::{Mutex, MutexGuard, OnceLock};

// The allocation ledger is process-global; tests in this binary serialize so
// in-flight clients from other tests never pollute a balance assertion.
fn ledger_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn golden_config() -> herdr_client_config {
    // Values of the committed golden hello fixture (endpoint-hello-v1.json),
    // so the drained hello frame must be byte-identical to client-20.bin.
    herdr_client_config {
        cols: 80,
        rows: 24,
        cell_width_px: 8,
        cell_height_px: 16,
        pixel_mouse: true,
        mouse_capture: true,
        max_frame_size: 0,
        outbound_message_limit: 0,
        outbound_byte_limit: 0,
    }
}

fn fixture(name: &str) -> Vec<u8> {
    let path = format!(
        "{}/../herdr-protocol/tests/fixtures/{}",
        env!("CARGO_MANIFEST_DIR"),
        name
    );
    std::fs::read(path).expect("committed fixture")
}

fn create_ok() -> *mut herdr_client {
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let client = herdr_client_create(&golden_config(), &mut error);
    assert_eq!(error.code, HERDR_CODE_OK, "create must succeed");
    assert!(!client.is_null());
    client
}

fn drain_one(client: *mut herdr_client) -> Vec<u8> {
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let bytes = herdr_client_drain_outbound(client, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    let data = if bytes.len == 0 {
        Vec::new()
    } else {
        // SAFETY (test): buffer handed out by drain_outbound, freed below.
        unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) }.to_vec()
    };
    herdr_bytes_free(bytes);
    data
}

fn receive(client: *mut herdr_client, bytes: &[u8]) -> HerdrResult {
    herdr_client_receive(client, bytes.as_ptr(), bytes.len())
}

#[test]
fn create_drains_the_golden_hello_frame_byte_for_byte() {
    let _guard = ledger_lock();
    let client = create_ok();
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_AWAITING_WELCOME);
    let hello = drain_one(client);
    assert_eq!(hello, fixture("golden/client-20.bin"));
    let next = drain_one(client);
    assert!(next.is_empty(), "exactly one queued frame at create");
    herdr_client_destroy(client);
}

#[test]
fn chunked_welcome_bytes_complete_the_handshake() {
    let _guard = ledger_lock();
    let client = create_ok();
    let welcome = fixture("golden/server-20.bin");
    // Given a truncated first chunk, the partial frame stays buffered.
    let result = receive(client, &welcome[..5]);
    assert_eq!(result.code, HERDR_CODE_OK);
    assert_eq!(herdr_client_pending_inbound(client), 5);
    // When the rest arrives, the welcome parses and the client goes online.
    let result = receive(client, &welcome[5..]);
    assert_eq!(result.code, HERDR_CODE_OK);
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_ONLINE);
    assert_eq!(herdr_client_pending_inbound(client), 0);
    herdr_client_destroy(client);
}

#[test]
fn golden_snapshot_frame_surfaces_through_the_snapshot_accessor() {
    let _guard = ledger_lock();
    let client = create_ok();
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(client, &fixture("golden/server-21.bin")).code,
        HERDR_CODE_OK
    );
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let bytes = herdr_client_snapshot(client, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    assert!(bytes.len > 0, "a golden snapshot must have been accepted");
    let json = unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) }.to_vec();
    herdr_bytes_free(bytes);
    let snapshot: serde_json::Value =
        serde_json::from_slice(&json).expect("snapshot accessor returns stable JSON");
    assert_eq!(snapshot["boot_id"], "boot-v1");
    assert_eq!(snapshot["revision"], 7);
    assert_eq!(snapshot["panes"][0]["pane_id"], "w1:p1");
    herdr_client_destroy(client);
}

#[test]
fn garbage_and_oversized_frames_fail_structurally_without_crashing() {
    let _guard = ledger_lock();
    let client = create_ok();
    // Oversized claimed length must be rejected before any allocation.
    let mut oversized = [0u8; 4];
    oversized.copy_from_slice(&u32::MAX.to_le_bytes());
    let result = receive(client, &oversized);
    assert_eq!(result.code, HERDR_CODE_PROTOCOL_VIOLATION);
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_FAILED);
    // A failed client answers later traffic with a structured error.
    let again = receive(client, &fixture("golden/server-20.bin"));
    assert_eq!(again.code, HERDR_CODE_CLIENT_FAILED);
    // Bincode garbage inside a plausible frame length fails too.
    let client2 = create_ok();
    let mut garbage = 64u32.to_le_bytes().to_vec();
    garbage.extend(std::iter::repeat(0xA5).take(64));
    let result = receive(client2, &garbage);
    assert_eq!(result.code, HERDR_CODE_PROTOCOL_VIOLATION);
    herdr_client_destroy(client);
    herdr_client_destroy(client2);
}

#[test]
fn null_and_invalid_arguments_return_structured_errors() {
    let _guard = ledger_lock();
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    assert!(herdr_client_create(ptr::null(), &mut error).is_null());
    assert_eq!(error.code, HERDR_CODE_INVALID_ARGUMENT);
    let mut bad = golden_config();
    bad.cols = 0;
    assert!(herdr_client_create(&bad, &mut error).is_null());
    assert_eq!(error.code, HERDR_CODE_INVALID_ARGUMENT);

    let client = create_ok();
    assert_eq!(
        herdr_client_receive(ptr::null_mut(), ptr::null(), 0).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_receive(client, ptr::null(), 4).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_send_input(client, ptr::null()).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(herdr_client_phase(ptr::null_mut()), u32::MAX);
    herdr_client_destroy(client);
    // Destroy of null is a documented no-op, not a crash.
    herdr_client_destroy(ptr::null_mut());
}

#[test]
fn input_before_handshake_or_snapshot_is_a_structured_error() {
    let _guard = ledger_lock();
    let client = create_ok();
    let pane = CString::new("w1:p1").expect("static");
    let text = CString::new("hello").expect("static");
    let input = herdr_input {
        kind: HERDR_INPUT_TEXT_COMMIT,
        pane_id: pane.as_ptr(),
        text: text.as_ptr(),
        key: herdr_key {
            code: HERDR_KEY_CHAR,
            codepoint: 'h' as u32,
            modifiers: 0,
            kind: HERDR_KEY_KIND_PRESS,
            repeat_count: 1,
            shifted_codepoint: 0,
        },
    };
    // Before the welcome: not online.
    let result = herdr_client_send_input(client, &input);
    assert_eq!(result.code, HERDR_CODE_NOT_ONLINE);
    // Online but before any snapshot: frozen.
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    let result = herdr_client_send_input(client, &input);
    assert_eq!(result.code, HERDR_CODE_INPUT_FROZEN);
    herdr_client_destroy(client);
}

#[test]
fn invalid_key_and_text_payloads_are_rejected_at_the_boundary() {
    let _guard = ledger_lock();
    let client = create_ok();
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    let pane = CString::new("w1:p1").expect("static");
    let mut input = herdr_input {
        kind: HERDR_INPUT_KEY,
        pane_id: pane.as_ptr(),
        text: ptr::null(),
        key: herdr_key {
            code: HERDR_KEY_CHAR,
            // Surrogate codepoints are not unicode scalars.
            codepoint: 0xD800,
            modifiers: 0,
            kind: HERDR_KEY_KIND_PRESS,
            repeat_count: 1,
            shifted_codepoint: 0,
        },
    };
    assert_eq!(
        herdr_client_send_input(client, &input).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    input.key.code = u32::MAX;
    assert_eq!(
        herdr_client_send_input(client, &input).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    input.key.code = HERDR_KEY_FUNCTION;
    input.key.codepoint = 99;
    assert_eq!(
        herdr_client_send_input(client, &input).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    // Missing or empty pane id is rejected.
    let empty_pane = CString::new("").expect("static");
    let text = CString::new("t").expect("static");
    let no_pane = herdr_input {
        kind: HERDR_INPUT_TEXT_COMMIT,
        pane_id: empty_pane.as_ptr(),
        text: text.as_ptr(),
        key: input.key,
    };
    assert_eq!(
        herdr_client_send_input(client, &no_pane).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    // Valid key shape reaches the state machine and reports frozen input.
    input.key.code = HERDR_KEY_CHAR;
    input.key.codepoint = 'h' as u32;
    assert_eq!(
        herdr_client_send_input(client, &input).code,
        HERDR_CODE_INPUT_FROZEN
    );
    herdr_client_destroy(client);
}

#[test]
fn every_allocation_is_returned_by_its_matching_free() {
    let _guard = ledger_lock();
    let before = herdr_debug_live_allocations();
    for _ in 0..8 {
        let client = create_ok();
        let mut error = HerdrResult {
            code: -1,
            detail: ptr::null(),
        };
        let bytes = herdr_client_drain_outbound(client, &mut error);
        herdr_bytes_free(bytes);
        assert_eq!(
            receive(client, &fixture("golden/server-20.bin")).code,
            HERDR_CODE_OK
        );
        assert_eq!(
            receive(client, &fixture("golden/server-21.bin")).code,
            HERDR_CODE_OK
        );
        let snapshot = herdr_client_snapshot(client, &mut error);
        herdr_bytes_free(snapshot);
        let surface = herdr_client_surface(client, &mut error);
        herdr_bytes_free(surface);
        herdr_client_destroy(client);
    }
    assert_eq!(
        herdr_debug_live_allocations(),
        before,
        "create/destroy and bytes alloc/free must balance exactly"
    );
}

#[test]
fn error_details_are_readable_utf8_until_the_next_call() {
    let _guard = ledger_lock();
    let client = create_ok();
    let mut oversized = [0u8; 4];
    oversized.copy_from_slice(&u32::MAX.to_le_bytes());
    let result = receive(client, &oversized);
    assert_eq!(result.code, HERDR_CODE_PROTOCOL_VIOLATION);
    let detail = unsafe { std::ffi::CStr::from_ptr(result.detail) };
    assert!(detail.to_string_lossy().contains("exceeds maximum"));
    herdr_client_destroy(client);
}

#[test]
fn version_string_is_static_and_nul_terminated() {
    let _guard = ledger_lock();
    let version = unsafe { std::ffi::CStr::from_ptr(herdr_core_version()) };
    assert_eq!(version.to_bytes(), b"0.9.0");
}

fn encode_server(message: &ServerMessage) -> Vec<u8> {
    let mut frame = Vec::new();
    write_message(&mut frame, message).expect("server frame encodes");
    frame
}

fn decode_client(frame: &[u8]) -> ClientMessage {
    let mut reader = std::io::Cursor::new(frame);
    herdr_protocol::read_message(&mut reader, u32::MAX as usize).expect("outbound frame decodes")
}

fn coherent_surface(cols: u16, rows: u16) -> ServerMessage {
    ServerMessage::PaneSurface(PaneSurfaceFrame {
        boot_id: "boot-v1".into(),
        projection_revision: 7,
        surface_revision: 1,
        frame: FrameData {
            width: cols,
            height: rows,
            cells: vec![
                CellData {
                    symbol: " ".into(),
                    fg: 0,
                    bg: 0,
                    modifier: 0,
                    skip: false,
                    hyperlink: None,
                };
                usize::from(cols) * usize::from(rows)
            ],
            cursor: None,
            hyperlinks: vec![],
            graphics: vec![],
        },
        panes: vec![PaneSurfacePane {
            pane_id: "w1:p1".into(),
            content_revision: 1,
            rect: SurfaceRect {
                x: 0,
                y: 0,
                width: cols,
                height: rows,
            },
            inner_rect: SurfaceRect {
                x: 0,
                y: 0,
                width: cols,
                height: rows,
            },
            scrollbar_rect: None,
            scroll: None,
            focused: true,
            mouse_reporting: false,
            sgr_pixel_mouse: false,
            alternate_screen_active: false,
            pixel_width: 0,
            pixel_height: 0,
        }],
        splits: vec![],
        popup: None,
        graphics: SurfaceGraphicsScene::default(),
    })
}

/// The activation transaction correlates its acknowledgement with the
/// request id it actually queued, so drain the queue and recover it.
fn drain_surface_set_request_id(client: *mut herdr_client) -> String {
    endpoint_request_id(&drain_outbound_messages(client), ":on")
}

fn drain_outbound_messages(client: *mut herdr_client) -> Vec<ClientMessage> {
    let mut messages = Vec::new();
    for _ in 0..64 {
        let frame = drain_one(client);
        if frame.is_empty() {
            break;
        }
        messages.push(decode_client(&frame));
    }
    messages
}

fn endpoint_request_id(messages: &[ClientMessage], suffix: &str) -> String {
    messages
        .iter()
        .find_map(|message| match message {
            ClientMessage::ClientShellEndpointRequest { request, .. } => {
                let value: serde_json::Value = serde_json::from_str(request).expect("request JSON");
                value["id"]
                    .as_str()
                    .filter(|id| id.ends_with(suffix))
                    .map(str::to_owned)
            }
            _ => None,
        })
        .unwrap_or_else(|| panic!("no endpoint request id ending with {suffix}"))
}

fn surface_set_ack(request_id: &str, revision: u64) -> Vec<u8> {
    let ack = ServerMessage::ClientShellEndpointResponseChunk {
        boot_id: "boot-v1".into(),
        request_id: request_id.to_owned(),
        final_chunk: true,
        data: serde_json::to_vec(&herdr_client_core::api::schema::SuccessResponse {
            id: request_id.to_owned(),
            result: herdr_client_core::api::schema::ResponseResult::ClientShellSurfaceSet {
                active: true,
                projection_revision: revision,
            },
        })
        .expect("ack JSON"),
    };
    encode_server(&ack)
}

/// Drives welcome → snapshot (the transaction begins) → surface.set(on)
/// ack → coherent surface: the first commit at the golden snapshot's
/// boot-v1/revision-7.
fn drive_to_surface_commit(client: *mut herdr_client) {
    drive_welcome_snapshot(client);
    drive_surface_commit(client);
}

fn drive_welcome_snapshot(client: *mut herdr_client) {
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(client, &fixture("golden/server-21.bin")).code,
        HERDR_CODE_OK
    );
}

fn drive_surface_commit(client: *mut herdr_client) {
    let on_id = drain_surface_set_request_id(client);
    assert_eq!(
        receive(client, &surface_set_ack(&on_id, 7)).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(client, &encode_server(&coherent_surface(80, 24))).code,
        HERDR_CODE_OK
    );
}

/// Completes the presentation fence after [`drive_to_surface_commit`]:
/// sync ack, re-sent evidence, ready control — the terminal `Activated`
/// completion that unfreezes the input lane.
fn drive_fence_to_activated(client: *mut herdr_client) {
    let sync_id = endpoint_request_id(&drain_outbound_messages(client), ":presentation-sync");
    assert_eq!(
        receive(client, &surface_set_ack(&sync_id, 7)).code,
        HERDR_CODE_OK
    );
    // The presentation-sync phase restarts with fresh evidence: the server
    // re-sends the snapshot and surface before the fence can complete.
    assert_eq!(
        receive(client, &fixture("golden/server-21.bin")).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(client, &encode_server(&coherent_surface(80, 24))).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(client, &encode_server(&fence_ready_control(client))).code,
        HERDR_CODE_OK
    );
}

/// The ready control must echo the token of the fence the client opened;
/// recover it from the queued presentation-sync control.
fn fence_ready_control(client: *mut herdr_client) -> ServerMessage {
    let token = drain_outbound_messages(client)
        .into_iter()
        .find_map(|message| match message {
            ClientMessage::EndpointControl { kind, data }
                if kind == "endpoint.presentation.sync.v1" =>
            {
                Some(data)
            }
            _ => None,
        })
        .expect("fence sync control queued");
    ServerMessage::EndpointControl {
        kind: "endpoint.presentation.ready.v1".into(),
        data: token,
    }
}

#[test]
fn presentation_fence_unfreezes_input_after_activation() {
    let _guard = ledger_lock();
    let client = create_ok();
    drive_to_surface_commit(client);
    // The first commit makes the surface visible while the fence keeps the
    // input lane frozen (AwaitingPresentationSync).
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let bytes = herdr_client_surface(client, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    assert!(bytes.len > 0, "first commit must expose the surface");
    herdr_bytes_free(bytes);
    let pane = CString::new("w1:p1").expect("static");
    let text = CString::new("hi").expect("static");
    let input = herdr_input {
        kind: HERDR_INPUT_TEXT_COMMIT,
        pane_id: pane.as_ptr(),
        text: text.as_ptr(),
        key: herdr_key {
            code: 0,
            codepoint: 0,
            modifiers: 0,
            kind: 0,
            repeat_count: 0,
            shifted_codepoint: 0,
        },
    };
    assert_eq!(
        herdr_client_send_input(client, &input).code,
        HERDR_CODE_INPUT_FROZEN
    );
    drive_fence_to_activated(client);
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_ONLINE);
    assert_eq!(herdr_client_send_input(client, &input).code, HERDR_CODE_OK);
    herdr_client_destroy(client);
}

#[test]
fn activation_commits_the_surface_after_welcome_snapshot_and_surface() {
    let _guard = ledger_lock();
    let client = create_ok();
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    // The welcome-time begin cannot start yet (no snapshot metadata); the
    // first accepted snapshot arms the transaction and queues its lifecycle
    // frames (resize + surface.set(on) + focus baseline).
    assert_eq!(
        receive(client, &fixture("golden/server-21.bin")).code,
        HERDR_CODE_OK
    );
    let request_id = drain_surface_set_request_id(client);
    // A resize mid-transaction routes through the activation: the pending
    // evidence is invalidated and the new geometry frame is re-queued.
    assert_eq!(herdr_client_resize(client, 100, 30).code, HERDR_CODE_OK);
    match decode_client(&drain_one(client)) {
        ClientMessage::ClientShellResize { surface_size, .. } => {
            assert_eq!((surface_size.cols, surface_size.rows), (100, 30));
        }
        other => panic!("expected the re-queued resize frame, got {other:?}"),
    }
    // Acknowledge surface interest at the snapshot's revision 7, then deliver
    // a coherent surface at the acknowledged revision and resized geometry.
    let ack = ServerMessage::ClientShellEndpointResponseChunk {
        boot_id: "boot-v1".into(),
        request_id: request_id.clone(),
        final_chunk: true,
        data: serde_json::to_vec(&herdr_client_core::api::schema::SuccessResponse {
            id: request_id,
            result: herdr_client_core::api::schema::ResponseResult::ClientShellSurfaceSet {
                active: true,
                projection_revision: 7,
            },
        })
        .expect("ack JSON"),
    };
    assert_eq!(receive(client, &encode_server(&ack)).code, HERDR_CODE_OK);
    assert_eq!(
        receive(client, &encode_server(&coherent_surface(100, 30))).code,
        HERDR_CODE_OK
    );
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_ONLINE);
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let bytes = herdr_client_surface(client, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    assert!(bytes.len > 0, "activation must commit the pane surface");
    let json = unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) }.to_vec();
    herdr_bytes_free(bytes);
    let surface: serde_json::Value =
        serde_json::from_slice(&json).expect("surface accessor returns stable JSON");
    assert_eq!(surface["boot_id"], "boot-v1");
    assert_eq!(surface["projection_revision"], 7);
    assert_eq!(surface["frame"]["width"], 100);
    assert_eq!(surface["frame"]["height"], 30);
    // The completion path queues the presentation-sync request; drain the
    // remaining lifecycle frames before the steady-state check.
    while !drain_one(client).is_empty() {}
    // Steady state: the endpoint projection is active, so a later snapshot
    // must not restart an activation transaction or queue lifecycle frames.
    assert_eq!(
        receive(client, &fixture("golden/server-21.bin")).code,
        HERDR_CODE_OK
    );
    assert!(
        drain_one(client).is_empty(),
        "no re-activation after the endpoint is active"
    );
    herdr_client_destroy(client);
}

#[test]
fn resize_rejects_out_of_bounds_and_queues_before_activation() {
    let _guard = ledger_lock();
    assert_eq!(
        herdr_client_resize(ptr::null_mut(), 80, 24).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    let client = create_ok();
    drain_one(client); // the golden hello queued at create
    assert_eq!(
        herdr_client_resize(client, 0, 24).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_resize(client, 80, 0).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_resize(client, u32::MAX, 24).code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(herdr_client_resize(client, 80, 24).code, HERDR_CODE_OK);
    // No transaction is in flight, so the resize is queued directly.
    match decode_client(&drain_one(client)) {
        ClientMessage::ClientShellResize {
            surface_size,
            cell_width_px,
            cell_height_px,
            pixel_mouse,
        } => {
            assert_eq!((surface_size.cols, surface_size.rows), (80, 24));
            assert_eq!((cell_width_px, cell_height_px), (8, 16));
            assert!(pixel_mouse);
        }
        other => panic!("expected the queued resize frame, got {other:?}"),
    }
    assert!(drain_one(client).is_empty(), "exactly one queued frame");
    herdr_client_destroy(client);
}

fn take_clipboard(client: *mut herdr_client) -> Option<Vec<u8>> {
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let bytes = herdr_client_take_clipboard(client, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    if bytes.len == 0 {
        return None;
    }
    // SAFETY (test): buffer handed out by take_clipboard, freed below.
    let data = unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) }.to_vec();
    herdr_bytes_free(bytes);
    Some(data)
}

#[test]
fn server_clipboard_decodes_once_into_the_one_shot_slot() {
    let _guard = ledger_lock();
    let client = create_ok();
    assert_eq!(take_clipboard(client), None, "empty before any frame");
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    assert_eq!(
        receive(
            client,
            &encode_server(&ServerMessage::Clipboard {
                data: "aGVsbG8=".into(),
            })
        )
        .code,
        HERDR_CODE_OK
    );
    assert_eq!(take_clipboard(client).as_deref(), Some(b"hello".as_slice()));
    assert_eq!(
        take_clipboard(client),
        None,
        "the slot is one-shot: a second take is empty"
    );
    herdr_client_destroy(client);
}

#[test]
fn oversized_or_malformed_clipboard_frames_are_dropped_but_not_fatal() {
    let _guard = ledger_lock();
    let mut config = golden_config();
    // The drop path must be exercised inside the frame ceiling.
    config.max_frame_size = 24 * 1024 * 1024;
    let mut error = HerdrResult {
        code: -1,
        detail: ptr::null(),
    };
    let client = herdr_client_create(&config, &mut error);
    assert_eq!(error.code, HERDR_CODE_OK);
    assert_eq!(
        receive(client, &fixture("golden/server-20.bin")).code,
        HERDR_CODE_OK
    );
    // 22.5M base64 chars decode past the 16 MiB clipboard cap; the payload
    // is dropped before the decode allocation.
    let oversized = ServerMessage::Clipboard {
        data: "A".repeat(22_500_000),
    };
    let result = receive(client, &encode_server(&oversized));
    assert_eq!(result.code, HERDR_CODE_CLIPBOARD_DROPPED);
    let detail = unsafe { std::ffi::CStr::from_ptr(result.detail) };
    assert!(detail.to_string_lossy().contains("protocol cap"));
    let malformed = ServerMessage::Clipboard {
        data: "!!!!".into(),
    };
    assert_eq!(
        receive(client, &encode_server(&malformed)).code,
        HERDR_CODE_CLIPBOARD_DROPPED
    );
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_ONLINE);
    assert_eq!(take_clipboard(client), None, "nothing was stored");
    // A later well-formed frame still lands after the drops.
    assert_eq!(
        receive(
            client,
            &encode_server(&ServerMessage::Clipboard {
                data: "aGVsbG8=".into(),
            })
        )
        .code,
        HERDR_CODE_OK
    );
    assert_eq!(take_clipboard(client).as_deref(), Some(b"hello".as_slice()));
    herdr_client_destroy(client);
}

#[test]
fn send_clipboard_image_guards_and_queues_the_bridge_frame() {
    let _guard = ledger_lock();
    let pane = CString::new("w1:p1").expect("static");
    let extension = CString::new("png").expect("static");
    let image = b"\x89PNG\r\n\x1a\n".to_vec();
    // Before the handshake: structured not-online, nothing queued.
    let client = create_ok();
    assert_eq!(
        herdr_client_send_clipboard_image(
            ptr::null_mut(),
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_NOT_ONLINE
    );
    // Online but mid-activation: the input lane is still frozen.
    drive_welcome_snapshot(client);
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_INPUT_FROZEN
    );
    // Null/empty argument shapes are rejected at the boundary.
    let oversized = vec![0u8; 16 * 1024 * 1024 + 1];
    drive_surface_commit(client);
    drive_fence_to_activated(client);
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            ptr::null(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    let empty = CString::new("").expect("static");
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            empty.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            0,
        )
        .code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            oversized.len(),
        )
        .code,
        HERDR_CODE_INVALID_ARGUMENT
    );
    // Happy path: exactly one ClipboardImage frame with the typed target.
    assert_eq!(
        herdr_client_send_clipboard_image(
            client,
            pane.as_ptr(),
            extension.as_ptr(),
            image.as_ptr(),
            image.len(),
        )
        .code,
        HERDR_CODE_OK
    );
    match drain_outbound_messages(client).as_slice() {
        [ClientMessage::ClipboardImage {
            target,
            extension,
            data,
        }] => {
            assert_eq!(
                *target,
                herdr_protocol::ClientClipboardImageTarget::Pane("w1:p1".into())
            );
            assert_eq!(extension, "png");
            assert_eq!(data, &image);
        }
        other => panic!("expected exactly the clipboard image frame, got {other:?}"),
    }
    herdr_client_destroy(client);
}
