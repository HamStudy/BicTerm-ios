//! Host-side FFI tests against the committed golden frames. These exercise
//! the exact extern "C" surface the xcframework ships.
use herdr_ios_ffi::*;
use herdr_protocol::{
    write_message, CellData, ClientMessage, FrameData, PaneSurfaceFrame, ServerMessage,
    SurfaceGraphicsScene,
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
        panes: vec![],
        splits: vec![],
        popup: None,
        graphics: SurfaceGraphicsScene::default(),
    })
}

/// The activation transaction correlates its acknowledgement with the
/// request id it actually queued, so recover it while draining the queue
/// down to empty.
fn drain_surface_set_request_id(client: *mut herdr_client) -> String {
    let mut found = None;
    for _ in 0..16 {
        let frame = drain_one(client);
        if frame.is_empty() {
            break;
        }
        if let ClientMessage::ClientShellEndpointRequest { request, .. } = decode_client(&frame) {
            let value: serde_json::Value = serde_json::from_str(&request).expect("request JSON");
            if value["method"] == "client_shell.surface.set" && value["params"]["active"] == true {
                found = value["id"].as_str().map(str::to_owned);
            }
        }
    }
    found.expect("activation never queued a surface.set(on) request")
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
