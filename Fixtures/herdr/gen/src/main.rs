//! T16 fixture generator + FFI probe (read-only consumer of Vendor/herdr).
//!
//! `--out <dir>`: writes, through the REAL extracted v0.9.0 codec
//! (`herdr_protocol::write_message`), the server-side frames the Swift UI
//! tests replay:
//!   - welcome-gen99.bin : endpoint welcome with generation 99 (version gate)
//!   - snapshot-2x2.bin  : `shell.snapshot.v1` carrier, 2x2 pane tree
//!   - surface-2x2.bin   : `ServerMessage::PaneSurface` matching that snapshot
//!   - surface-2x2.json  : serde JSON of the same `PaneSurfaceFrame` (the
//!     exact shape `herdr_client_surface` returns once a surface commits)
//!
//! `--probe --golden <dir>`: feeds welcome + snapshot + surface through the
//! COMMITTED C ABI (`herdr_client_*`) and records whether the surface
//! accessor can ever yield data. Expected finding (T16 blocker): the FFI
//! never activates the shell's endpoint projection, so `PaneSurface` frames
//! are rejected with HERDR_CODE_SURFACE_REJECTED and `herdr_client_surface`
//! stays empty. Output is printed for the evidence log.

use herdr_ios_ffi::{
    herdr_bytes_free, herdr_client_create, herdr_client_destroy, herdr_client_phase,
    herdr_client_receive, herdr_client_surface, HerdrResult, herdr_client_config,
};
use herdr_protocol::endpoint::{EndpointServerWelcome, ENDPOINT_WELCOME_KIND};
use herdr_protocol::{
    CellData, ClientShellPane, ClientShellProductAnnouncement, ClientShellSnapshot,
    ClientShellTab, ClientShellWorkspace, CursorState, FrameData, PaneSurfaceFrame,
    PaneSurfacePane, PaneSurfaceScrollMetrics, PaneSurfaceSplit, PaneSurfaceSplitDirection,
    ServerMessage, SurfaceRect, write_message,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    match mode {
        "--out" => {
            let dir = args.get(2).expect("usage: --out <dir>").clone();
            generate(&dir);
            println!("fixtures written to {dir}");
        }
        "--probe" => {
            let index = args.iter().position(|a| a == "--golden").expect("--golden <dir>");
            let golden = args[index + 1].clone();
            let fixtures = match args.iter().position(|a| a == "--fixtures") {
                Some(index) => args[index + 1].clone(),
                None => golden.clone(),
            };
            probe(&golden, &fixtures);
        }
        _ => {
            eprintln!("usage: herdr-fixture-gen --out <dir> | --probe --golden <dir>");
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
fn generate(dir: &str) {
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

    // 3. Pane surface matching the snapshot identity (boot + revision).
    let surface = surface_2x2();
    write_frame(dir, "surface-2x2.bin", &ServerMessage::PaneSurface(surface.clone()));
    let json = serde_json::to_string_pretty(&surface).expect("surface JSON");
    std::fs::write(format!("{dir}/surface-2x2.json"), json).expect("write surface JSON");

    // 3b. Endpoint response acknowledging the activation's surface-set
    // request. Serials are deterministic: the welcome-time begin attempt
    // consumes serial 1 (it fails preflight — no lease without a snapshot),
    // so the snapshot-time transaction that succeeds is serial 2 and its
    // request id is "client-shell-surface:2:on". The acknowledged
    // projection revision must match the snapshot AND surface (1).
    #[derive(serde::Serialize)]
    struct Envelope<'a> {
        id: &'a str,
        result: herdr_client_core::api::schema::ResponseResult,
    }
    let ack = Envelope {
        id: "client-shell-surface:2:on",
        result: herdr_client_core::api::schema::ResponseResult::ClientShellSurfaceSet {
            active: true,
            projection_revision: REVISION,
        },
    };
    write_frame(
        dir,
        "surface-ack-2x2.bin",
        &ServerMessage::ClientShellEndpointResponseChunk {
            boot_id: BOOT.into(),
            request_id: "client-shell-surface:2:on".into(),
            final_chunk: true,
            data: serde_json::to_vec(&ack).expect("ack JSON"),
        },
    );
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
    let mut bytes = Vec::new();
    write_message(&mut bytes, message).expect("encode frame");
    std::fs::write(format!("{dir}/{name}"), bytes).expect("write frame");
}

// ---------------------------------------------------------------------------
// FFI probe
// ---------------------------------------------------------------------------

fn probe(golden_dir: &str, fixture_dir: &str) {
    println!("== T16 FFI surface-path probe ==");
    println!("golden dir: {golden_dir}");
    let welcome = std::fs::read(format!("{golden_dir}/server-20.bin")).expect("golden welcome");
    let snapshot = std::fs::read(format!("{golden_dir}/server-21.bin")).expect("golden snapshot");
    let ack = std::fs::read(format!("{fixture_dir}/surface-ack-2x2.bin")).expect("ack");
    let surface = std::fs::read(format!("{fixture_dir}/surface-2x2.bin")).expect("surface");

    println!("probe fixtures generated in-memory (no writes needed)");

    {
        let config = herdr_client_config {
            cols: 80,
            rows: 24,
            cell_width_px: 8,
            cell_height_px: 16,
            pixel_mouse: false,
            mouse_capture: false,
            max_frame_size: 0,
            outbound_message_limit: 0,
            outbound_byte_limit: 0,
        };
        let mut error = HerdrResult { code: -1, detail: std::ptr::null() };
        let client = herdr_client_create(&config, &mut error);
        assert!(!client.is_null(), "create failed: {}", error.code);
        println!("created client (phase {})", herdr_client_phase(client));

        let feed = |label: &str, bytes: &[u8]| {
            let r = herdr_client_receive(client, bytes.as_ptr(), bytes.len());
            let mut e2 = HerdrResult { code: -1, detail: std::ptr::null() };
            let bytes_now = herdr_client_surface(client, &mut e2);
            println!(
                "receive({label:<18}) -> code {} phase {} surface_len {}",
                r.code,
                herdr_client_phase(client),
                bytes_now.len
            );
            herdr_bytes_free(bytes_now);
            loop {
                let mut e3 = HerdrResult { code: -1, detail: std::ptr::null() };
                let frame = herdr_ios_ffi::herdr_client_drain_outbound(client, &mut e3);
                if frame.len == 0 {
                    herdr_bytes_free(frame);
                    break;
                }
                let data = unsafe { std::slice::from_raw_parts(frame.data, frame.len) }.to_vec();
                herdr_bytes_free(frame);
                match herdr_protocol::read_message::<_, herdr_protocol::ClientMessage>(
                    &mut data.as_slice(),
                    16 * 1024 * 1024,
                ) {
                    Ok(message) => println!("    outbound -> {message:?}"),
                    Err(err) => println!("    outbound -> <decode error {err:?}>"),
                }
            }
        };

        feed("golden welcome", &welcome);
        feed("snapshot-2x2", &std::fs::read(format!("{fixture_dir}/snapshot-2x2.bin")).expect("snapshot fixture"));
        feed("surface-ack", &ack);
        feed("surface-2x2", &surface);
        let _ = snapshot;
        herdr_client_destroy(client);
        println!("destroyed; probe complete");
    }
}
