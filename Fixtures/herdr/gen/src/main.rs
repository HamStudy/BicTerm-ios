//! T16 fixture generator + FFI probe (read-only consumer of Vendor/herdr).
//!
//! `--out <dir> [--golden <dir>]`: writes, through the REAL extracted v0.9.0
//! codec (`herdr_protocol::write_message`), the server-side frames the Swift
//! UI tests replay:
//!   - welcome-gen99.bin : endpoint welcome with generation 99 (version gate)
//!   - snapshot-2x2.bin  : `shell.snapshot.v1` carrier, 2x2 pane tree
//!   - snapshot-2x2-rev2.bin / snapshot-2x2-rev3-solo.bin : later revisions
//!   - surface-2x2.bin   : `ServerMessage::PaneSurface` matching that snapshot
//!   - surface-2x2.json  : serde JSON of the same `PaneSurfaceFrame` (the
//!     exact shape `herdr_client_surface` returns once a surface commits)
//!   - surface-2x2-rev3-solo.bin : single-pane surface at revision 3
//!
//! T17: the fence + input fixtures are produced by DRIVING an in-process FFI
//! client through the activation transaction, so request ids and the fence
//! token are recovered from the client's real outbound frames (never
//! hardcoded serials):
//!   - surface-ack-2x2.bin      : ack for the recovered ":on" request id
//!   - surface-sync-ack-2x2.bin : ack for the recovered ":presentation-sync" id
//!   - presentation-ready-2x2.bin : ready control echoing the recovered token
//!   - input-*.bin              : exact client frames the FFI emits for each
//!     semantic input vector (echo-assert goldens for the Swift suites)
//!
//! `--probe --golden <dir>`: feeds welcome + snapshot + ack + surface through
//! the COMMITTED C ABI (`herdr_client_*`) and prints every outbound frame.

use herdr_ios_ffi::{
    HerdrResult, herdr_bytes_free, herdr_client_create, herdr_client_destroy, herdr_client_phase,
    herdr_client_receive, herdr_client_resize, herdr_client_send_input, herdr_client_surface,
    herdr_client_config, herdr_input, herdr_key,
    HERDR_CODE_INPUT_FROZEN, HERDR_CODE_OK, HERDR_INPUT_KEY, HERDR_INPUT_TEXT_COMMIT,
    HERDR_KEY_CHAR, HERDR_KEY_DOWN, HERDR_KEY_END, HERDR_KEY_ESC, HERDR_KEY_HOME,
    HERDR_KEY_KIND_PRESS, HERDR_KEY_LEFT, HERDR_KEY_PAGE_DOWN, HERDR_KEY_PAGE_UP,
    HERDR_KEY_RIGHT, HERDR_KEY_UP, HERDR_PHASE_ONLINE,
};
use herdr_protocol::endpoint::{EndpointServerWelcome, ENDPOINT_WELCOME_KIND};
use herdr_protocol::{
    CellData, ClientMessage, ClientShellPane, ClientShellProductAnnouncement, ClientShellSnapshot,
    ClientShellTab, ClientShellWorkspace, CursorState, FrameData, PaneSurfaceFrame,
    PaneSurfacePane, PaneSurfaceScrollMetrics, PaneSurfaceSplit, PaneSurfaceSplitDirection,
    ServerMessage, SurfaceRect, write_message,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let golden = args
        .iter()
        .position(|a| a == "--golden")
        .map(|index| args[index + 1].clone())
        .unwrap_or_else(|| "Vendor/herdr/herdr-protocol/tests/fixtures/golden".to_string());
    match mode {
        "--out" => {
            let dir = args.get(2).expect("usage: --out <dir>").clone();
            generate(&dir, &golden);
            println!("fixtures written to {dir}");
        }
        "--probe" => {
            let fixtures = match args.iter().position(|a| a == "--fixtures") {
                Some(index) => args[index + 1].clone(),
                None => "Fixtures/herdr/golden".to_string(),
            };
            probe(&golden, &fixtures);
        }
        _ => {
            eprintln!(
                "usage: herdr-fixture-gen --out <dir> [--golden <dir>] | --probe [--golden <dir>] [--fixtures <dir>]"
            );
            std::process::exit(2);
        }
    }
}

// ---------------------------------------------------------------------------
// Fixture construction
// ---------------------------------------------------------------------------

const BOOT: &str = "boot-2x2";
const REVISION: u64 = 1;
const COLS: u16 = 80;
const ROWS: u16 = 24;
fn generate(dir: &str, golden: &str) {
    std::fs::create_dir_all(dir).expect("create fixture dir");

    // 1. Incompatible welcome: generation 99, otherwise fully capable.
    let mut welcome = EndpointServerWelcome::compatible(vec!["client_shell.surface.set".into()]);
    welcome.generation = 99;
    welcome.server_version = "0.99.0-fixture".into();
    write_frame(dir, "welcome-gen99.bin", &ServerMessage::EndpointControl {
        kind: ENDPOINT_WELCOME_KIND.into(),
        data: serde_json::to_string(&welcome).expect("welcome JSON"),
    });

    // 2. Snapshot carrier: one workspace, one tab, four panes, focus on p2.
    let snapshot = snapshot_2x2();
    write_frame(dir, "snapshot-2x2.bin", &endpoint_snapshot_message(&snapshot));

    // 2b. Revision 2 of the same boot: focus moves to p3 (churn + focus switch).
    let mut revision2 = snapshot_2x2();
    revision2.revision = 2;
    revision2.focused_pane_id = Some("w1:p3".into());
    for pane in revision2.panes.iter_mut() {
        pane.focused = pane.pane_id == "w1:p3";
    }
    write_frame(dir, "snapshot-2x2-rev2.bin", &endpoint_snapshot_message(&revision2));

    // 2c. Revision 3: p2/p3/p4 are gone, only w1:p1 remains (stale-target lane).
    let solo = snapshot_rev3_solo();
    write_frame(dir, "snapshot-2x2-rev3-solo.bin", &endpoint_snapshot_message(&solo));

    // 3. Pane surface matching the snapshot identity (boot + revision).
    let surface = surface_2x2();
    write_frame(dir, "surface-2x2.bin", &ServerMessage::PaneSurface(surface.clone()));
    let json = serde_json::to_string_pretty(&surface).expect("surface JSON");
    std::fs::write(format!("{dir}/surface-2x2.json"), json).expect("write surface JSON");

    // 3b. The revision-3 single-pane surface (coherent with snapshot rev3).
    write_frame(
        dir,
        "surface-2x2-rev3-solo.bin",
        &ServerMessage::PaneSurface(surface_rev3_solo()),
    );

    // 4. Fence + input goldens, driven through the committed C ABI so the
    // recovered request ids and fence token are always the client's own.
    drive_fence_and_input_goldens(dir, golden);
}

fn snapshot_rev3_solo() -> ClientShellSnapshot {
    let mut solo = snapshot_2x2();
    solo.revision = 3;
    solo.focused_pane_id = Some("w1:p1".into());
    solo.panes.truncate(1);
    solo.panes[0].focused = true;
    solo
}

fn surface_rev3_solo() -> PaneSurfaceFrame {
    let mut surface = surface_2x2();
    surface.projection_revision = 3;
    surface.surface_revision = 3;
    surface.panes.truncate(1);
    surface.panes[0].focused = true;
    surface.panes[0].rect = SurfaceRect { x: 0, y: 0, width: COLS, height: ROWS };
    surface.panes[0].inner_rect = SurfaceRect {
        x: 1,
        y: 1,
        width: COLS - 2,
        height: ROWS - 2,
    };
    surface.panes[0].pixel_width = u32::from(COLS) * 8;
    surface.panes[0].pixel_height = u32::from(ROWS) * 16;
    surface.splits.clear();
    surface
}

fn endpoint_snapshot_message(snapshot: &ClientShellSnapshot) -> ServerMessage {
    herdr_protocol::endpoint::snapshot_message(snapshot).expect("snapshot JSON")
}

fn snapshot_2x2() -> ClientShellSnapshot {
    let workspace = ClientShellWorkspace {
        workspace_id: "w1".into(),
        active_tab_id: "w1:t1".into(),
        new_workspace_cwd: "/home/dev".into(),
        number: 1,
        label: "main".into(),
        custom_label: false,
        branch: Some("feature/herdr-ui".into()),
        git_ahead_behind: Some((2, 1)),
        tokens: vec![],
        worktree: None,
        focused: true,
        agent_status: herdr_protocol::AgentStatus::Working,
    };
    let tab = ClientShellTab {
        tab_id: "w1:t1".into(),
        workspace_id: "w1".into(),
        number: 1,
        label: "edit".into(),
        custom_label: false,
        zoomed: false,
        focused: true,
        agent_status: herdr_protocol::AgentStatus::Idle,
    };
    let pane = |pane_id: &str, focused: bool, cwd: &str| ClientShellPane {
        pane_id: pane_id.into(),
        workspace_id: "w1".into(),
        tab_id: "w1:t1".into(),
        label: Some(format!("pane {pane_id}")),
        cwd: Some(cwd.into()),
        foreground_cwd: Some(cwd.into()),
        focused,
        right_click_passthrough: false,
    };
    ClientShellSnapshot {
        boot_id: BOOT.into(),
        revision: REVISION,
        config_diagnostic: None,
        product_announcement: Some(ClientShellProductAnnouncement {
            version: "0.9.0".into(),
            id: "fixture-announce".into(),
            title: "Fixture announcement".into(),
            body: "Informational only; never actionable from the client.".into(),
            preview: false,
        }),
        update_available: None,
        update_install_command: String::new(),
        server_keybindings_toml: None,
        latest_release_notes_available: false,
        integration_updates_available: false,
        worktree_directory: "/home/dev/herdr".into(),
        release_notes: None,
        focused_workspace_id: Some("w1".into()),
        focused_tab_id: Some("w1:t1".into()),
        focused_pane_id: Some("w1:p2".into()),
        tab_bar_right: vec![],
        tab_bar_right_separator: "|".into(),
        agent_view_label: None,
        agent_order: vec![],
        workspaces: vec![workspace],
        tabs: vec![tab],
        panes: vec![
            pane("w1:p1", false, "/home/dev/src"),
            pane("w1:p2", true, "/home/dev/src/app"),
            pane("w1:p3", false, "/home/dev/logs"),
            pane("w1:p4", false, "/home/dev"),
        ],
        agents: vec![],
        commands: vec![],
    }
}

fn surface_2x2() -> PaneSurfaceFrame {
    // 2x2 grid of panes inside an 80x24 surface; row 0 reserved for nothing
    // (the surface IS the active tab area), borders on the mid lines.
    let half_cols = COLS / 2; // 40
    let half_rows = ROWS / 2; // 12
    let rect = |x: u16, y: u16| SurfaceRect { x, y, width: half_cols, height: half_rows };
    let layout: [(&str, SurfaceRect, bool, u16, &str); 4] = [
        ("w1:p1", rect(0, 0), false, 0, "/home/dev/src"),
        ("w1:p2", rect(half_cols, 0), true, 1, "/home/dev/src/app"),
        ("w1:p3", rect(0, half_rows), false, 2, "/home/dev/logs"),
        ("w1:p4", rect(half_cols, half_rows), false, 3, "/home/dev"),
    ];
    let panes: Vec<PaneSurfacePane> = layout
        .iter()
        .map(|&(pane_id, outer, focused, index, _cwd)| PaneSurfacePane {
            pane_id: pane_id.into(),
            content_revision: REVISION + u64::from(index),
            rect: outer,
            inner_rect: SurfaceRect {
                x: outer.x.saturating_add(1),
                y: outer.y.saturating_add(1),
                width: outer.width.saturating_sub(2),
                height: outer.height.saturating_sub(2),
            },
            scrollbar_rect: None,
            scroll: Some(PaneSurfaceScrollMetrics {
                offset_from_bottom: 0,
                max_offset_from_bottom: 0,
                viewport_rows: u64::from(outer.height.saturating_sub(2)),
            }),
            focused,
            mouse_reporting: false,
            sgr_pixel_mouse: false,
            alternate_screen_active: false,
            pixel_width: u32::from(outer.width) * 8,
            pixel_height: u32::from(outer.height) * 16,
        })
        .collect();

    let mut cells = Vec::with_capacity(usize::from(COLS) * usize::from(ROWS));
    for y in 0..ROWS {
        for x in 0..COLS {
            let border = x == half_cols || y == half_rows;
            cells.push(cell_for(x, y, border));
        }
    }
    // Distinct per-pane headline content, drawn inside each inner rect.
    for (index, (pane_id, outer, _, _, cwd)) in layout.iter().enumerate() {
        let text = format!("{pane_id} {cwd}");
        for (offset, ch) in text.chars().enumerate() {
            let x = usize::from(outer.x + 2) + offset;
            let y = usize::from(outer.y + 2 + u16::try_from(index / 2).unwrap());
            let cell = &mut cells[y * usize::from(COLS) + x];
            cell.symbol = ch.to_string();
            cell.fg = herdr_rgb(0xE6, 0xED, 0xF3);
        }
    }

    PaneSurfaceFrame {
        boot_id: BOOT.into(),
        projection_revision: REVISION,
        surface_revision: REVISION,
        frame: FrameData {
            cells,
            width: COLS,
            height: ROWS,
            cursor: Some(CursorState { x: half_cols + 2, y: 2, visible: true, shape: 2 }),
            hyperlinks: vec![],
            graphics: vec![],
        },
        panes: panes.to_vec(),
        splits: vec![
            PaneSurfaceSplit {
                direction: PaneSurfaceSplitDirection::Vertical,
                pos: half_cols,
                area: SurfaceRect { x: half_cols, y: 0, width: 1, height: ROWS },
                hit_rect: SurfaceRect {
                    x: half_cols.saturating_sub(1),
                    y: 0,
                    width: 3,
                    height: ROWS,
                },
                path: vec![],
            },
            PaneSurfaceSplit {
                direction: PaneSurfaceSplitDirection::Horizontal,
                pos: half_rows,
                area: SurfaceRect { x: 0, y: half_rows, width: COLS, height: 1 },
                hit_rect: SurfaceRect {
                    x: 0,
                    y: half_rows.saturating_sub(1),
                    width: COLS,
                    height: 3,
                },
                path: vec![],
            },
        ],
        popup: None,
        graphics: Default::default(),
    }
}

fn cell_for(x: u16, y: u16, border: bool) -> CellData {
    let half_cols = COLS / 2;
    let half_rows = ROWS / 2;
    let (symbol, fg, bg) = if border {
        let glyph = if x == half_cols && y == half_rows {
            "┼"
        } else if y == half_rows {
            "─"
        } else {
            "│"
        };
        (glyph.to_string(), herdr_rgb(0x30, 0x3A, 0x46), 0)
    } else if y == 0 {
        (" ".to_string(), 0, 0)
    } else {
        (" ".to_string(), 0, herdr_rgb(0x0D, 0x11, 0x17))
    };
    CellData { symbol, fg, bg, modifier: 0, skip: false, hyperlink: None }
}

fn herdr_rgb(r: u8, g: u8, b: u8) -> u32 {
    0x02_00_00_00 | (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b)
}

fn write_frame(dir: &str, name: &str, message: &ServerMessage) {
    std::fs::write(format!("{dir}/{name}"), encode_server(message)).expect("write frame");
}

fn encode_server(message: &ServerMessage) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_message(&mut bytes, message).expect("encode frame");
    bytes
}

// ---------------------------------------------------------------------------
// FFI-driven fence + input goldens
// ---------------------------------------------------------------------------

fn ffi_config() -> herdr_client_config {
    herdr_client_config {
        cols: 80,
        rows: 24,
        cell_width_px: 8,
        cell_height_px: 16,
        pixel_mouse: false,
        mouse_capture: false,
        max_frame_size: 0,
        outbound_message_limit: 0,
        outbound_byte_limit: 0,
    }
}

fn create_client(config: &herdr_client_config) -> *mut herdr_ios_ffi::herdr_client {
    let mut error = HerdrResult { code: -1, detail: std::ptr::null() };
    let client = herdr_client_create(config, &mut error);
    assert!(!client.is_null(), "create failed: {}", error.code);
    client
}

fn receive_or_die(client: *mut herdr_ios_ffi::herdr_client, label: &str, bytes: &[u8]) {
    let result = herdr_client_receive(client, bytes.as_ptr(), bytes.len());
    assert_eq!(result.code, HERDR_CODE_OK, "receive({label}) failed");
}

fn drain_one(client: *mut herdr_ios_ffi::herdr_client) -> Vec<u8> {
    let mut error = HerdrResult { code: -1, detail: std::ptr::null() };
    let frame = herdr_ios_ffi::herdr_client_drain_outbound(client, &mut error);
    let data = if frame.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(frame.data, frame.len) }.to_vec()
    };
    herdr_bytes_free(frame);
    data
}

fn drain_all(client: *mut herdr_ios_ffi::herdr_client, verbose: bool) -> Vec<ClientMessage> {
    let mut messages = Vec::new();
    for _ in 0..64 {
        let frame = drain_one(client);
        if frame.is_empty() {
            break;
        }
        let message =
            herdr_protocol::read_message::<_, ClientMessage>(&mut frame.as_slice(), 16 * 1024 * 1024)
                .expect("decode outbound");
        if verbose {
            println!("    outbound -> {message:?}");
        }
        messages.push(message);
    }
    messages
}

fn drain_request_id(client: *mut herdr_ios_ffi::herdr_client, suffix: &str, verbose: bool) -> String {
    drain_all(client, verbose)
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

fn drain_sync_token(client: *mut herdr_ios_ffi::herdr_client, verbose: bool) -> String {
    drain_all(client, verbose)
        .into_iter()
        .find_map(|message| match message {
            ClientMessage::EndpointControl { kind, data }
                if kind == herdr_protocol::endpoint::PRESENTATION_EFFECTS_SYNC_KIND =>
            {
                Some(data)
            }
            _ => None,
        })
        .expect("fence sync control queued")
}

fn surface_set_ack_message(request_id: &str, revision: u64) -> ServerMessage {
    ServerMessage::ClientShellEndpointResponseChunk {
        boot_id: BOOT.into(),
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
    }
}

struct FenceFixtures {
    on_ack: Vec<u8>,
    sync_ack: Vec<u8>,
    ready: Vec<u8>,
}

/// Runs the full presentation fence against one client: welcome, snapshot,
/// surface.set(on) ack, first surface commit (visible but input-frozen —
/// asserted), sync ack, evidence resend, ready control. Returns the three
/// correlated server fixtures so the caller can persist them.
fn drive_to_online(
    client: *mut herdr_ios_ffi::herdr_client,
    welcome: &[u8],
    snapshot: &[u8],
    surface: &[u8],
    verbose: bool,
) -> FenceFixtures {
    receive_or_die(client, "welcome", welcome);
    receive_or_die(client, "snapshot", snapshot);
    let on_id = drain_request_id(client, ":on", verbose);
    let on_ack = encode_server(&surface_set_ack_message(&on_id, REVISION));
    receive_or_die(client, "ack(:on)", &on_ack);
    receive_or_die(client, "surface commit 1", surface);
    let frozen = send_text(client, "w1:p2", "hi");
    assert_eq!(
        frozen.code, HERDR_CODE_INPUT_FROZEN,
        "input before the fence completes must bounce as frozen"
    );
    let sync_id = drain_request_id(client, ":presentation-sync", verbose);
    let sync_ack = encode_server(&surface_set_ack_message(&sync_id, REVISION));
    receive_or_die(client, "ack(:presentation-sync)", &sync_ack);
    receive_or_die(client, "snapshot resend", snapshot);
    receive_or_die(client, "surface commit 2", surface);
    let token = drain_sync_token(client, verbose);
    let ready = encode_server(&ServerMessage::EndpointControl {
        kind: herdr_protocol::endpoint::PRESENTATION_EFFECTS_READY_KIND.into(),
        data: token,
    });
    receive_or_die(client, "presentation ready", &ready);
    assert_eq!(herdr_client_phase(client), HERDR_PHASE_ONLINE);
    assert!(
        drain_one(client).is_empty(),
        "no residual outbound after activation"
    );
    FenceFixtures { on_ack, sync_ack, ready }
}

fn send_text(client: *mut herdr_ios_ffi::herdr_client, pane: &str, text: &str) -> HerdrResult {
    let pane = std::ffi::CString::new(pane).expect("pane");
    let text = std::ffi::CString::new(text).expect("text");
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
    herdr_client_send_input(client, &input)
}

fn send_key(
    client: *mut herdr_ios_ffi::herdr_client,
    pane: &str,
    code: u32,
    codepoint: u32,
    modifiers: u8,
) -> HerdrResult {
    let pane = std::ffi::CString::new(pane).expect("pane");
    let input = herdr_input {
        kind: HERDR_INPUT_KEY,
        pane_id: pane.as_ptr(),
        text: std::ptr::null(),
        key: herdr_key {
            code,
            codepoint,
            modifiers,
            kind: HERDR_KEY_KIND_PRESS,
            repeat_count: 1,
            shifted_codepoint: 0,
        },
    };
    herdr_client_send_input(client, &input)
}

fn write_drained(dir: &str, name: &str, client: *mut herdr_ios_ffi::herdr_client) {
    let mut bytes = Vec::new();
    loop {
        let frame = drain_one(client);
        if frame.is_empty() {
            break;
        }
        bytes.extend_from_slice(&frame);
    }
    assert!(!bytes.is_empty(), "{name} produced no outbound frame");
    std::fs::write(format!("{dir}/{name}"), bytes).expect("write input golden");
}

fn drive_fence_and_input_goldens(dir: &str, golden: &str) {
    let welcome = std::fs::read(format!("{golden}/server-20.bin")).expect("golden welcome");
    let snapshot = std::fs::read(format!("{dir}/snapshot-2x2.bin")).expect("snapshot fixture");
    let surface = std::fs::read(format!("{dir}/surface-2x2.bin")).expect("surface fixture");
    let client = create_client(&ffi_config());
    let fence = drive_to_online(client, &welcome, &snapshot, &surface, false);
    std::fs::write(format!("{dir}/surface-ack-2x2.bin"), fence.on_ack).expect("write ack");
    std::fs::write(format!("{dir}/surface-sync-ack-2x2.bin"), fence.sync_ack)
        .expect("write sync ack");
    std::fs::write(format!("{dir}/presentation-ready-2x2.bin"), fence.ready)
        .expect("write ready");

    for (name, pane, text) in [
        ("input-text-hi-p2.bin", "w1:p2", "hi"),
        ("input-text-cjk-p2.bin", "w1:p2", "こんにちは世界"),
        ("input-text-x-p3.bin", "w1:p3", "x"),
        ("input-text-q-p1.bin", "w1:p1", "q"),
    ] {
        assert_eq!(send_text(client, pane, text).code, HERDR_CODE_OK);
        write_drained(dir, name, client);
    }
    for (name, code, codepoint, modifiers) in [
        ("input-key-ctrl-c-p2.bin", HERDR_KEY_CHAR, u32::from(b'c'), 2u8),
        ("input-key-esc-p2.bin", HERDR_KEY_ESC, 0, 0),
        ("input-key-home-p2.bin", HERDR_KEY_HOME, 0, 0),
        ("input-key-end-p2.bin", HERDR_KEY_END, 0, 0),
        ("input-key-pageup-p2.bin", HERDR_KEY_PAGE_UP, 0, 0),
        ("input-key-pagedown-p2.bin", HERDR_KEY_PAGE_DOWN, 0, 0),
        ("input-key-up-p2.bin", HERDR_KEY_UP, 0, 0),
        ("input-key-down-p2.bin", HERDR_KEY_DOWN, 0, 0),
        ("input-key-left-p2.bin", HERDR_KEY_LEFT, 0, 0),
        ("input-key-right-p2.bin", HERDR_KEY_RIGHT, 0, 0),
    ] {
        assert_eq!(send_key(client, "w1:p2", code, codepoint, modifiers).code, HERDR_CODE_OK);
        write_drained(dir, name, client);
    }
    assert_eq!(herdr_client_resize(client, 100, 30).code, HERDR_CODE_OK);
    write_drained(dir, "input-resize-100x30.bin", client);
    herdr_client_destroy(client);
}

// ---------------------------------------------------------------------------
// FFI probe
// ---------------------------------------------------------------------------

fn probe(golden_dir: &str, fixture_dir: &str) {
    println!("== herdr FFI presentation-fence probe ==");
    println!("golden dir: {golden_dir}");
    println!("fixture dir: {fixture_dir}");
    let welcome = std::fs::read(format!("{golden_dir}/server-20.bin")).expect("golden welcome");
    let snapshot = std::fs::read(format!("{fixture_dir}/snapshot-2x2.bin")).expect("snapshot fixture");
    let surface = std::fs::read(format!("{fixture_dir}/surface-2x2.bin")).expect("surface fixture");

    let client = create_client(&ffi_config());
    println!("created client (phase {})", herdr_client_phase(client));
    drive_to_online(client, &welcome, &snapshot, &surface, true);
    let mut error = HerdrResult { code: -1, detail: std::ptr::null() };
    let bytes = herdr_client_surface(client, &mut error);
    println!("phase online; surface_len {} (code {})", bytes.len, error.code);
    herdr_bytes_free(bytes);

    let sent = send_text(client, "w1:p2", "hi");
    println!("send_input(text hi -> w1:p2) -> code {}", sent.code);
    drain_all(client, true);
    let resized = herdr_client_resize(client, 100, 30);
    println!("resize(100x30) -> code {}", resized.code);
    drain_all(client, true);
    herdr_client_destroy(client);
    println!("destroyed; probe complete");
}
