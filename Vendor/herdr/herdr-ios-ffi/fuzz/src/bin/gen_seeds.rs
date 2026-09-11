//! Seed-corpus generator for the herdr fuzz targets. Run from the repository
//! root (normal toolchain, no sanitizer):
//!
//! ```sh
//! cargo run --manifest-path Vendor/herdr/herdr-ios-ffi/fuzz/Cargo.toml \
//!     --bin gen_seeds
//! ```
//!
//! Seeds come from the committed conformance fixtures: framed golden server
//! vectors (length_parse), their payloads with the 4-byte prefix stripped
//! (bincode_decode), the stable JSON carriers (endpoint_json), and
//! hand-coherent patch frames against the committed revision-2 surface
//! (patch_apply). Committed outputs are deterministic; rerunning is stable.
use herdr_protocol::{
    write_message, CellData, CursorState, FrameData, PaneSurfacePane, PaneSurfacePatch,
    PaneSurfacePatchRow, ServerMessage, SurfaceRect, MAX_FRAME_SIZE,
};
use std::fs;
use std::io::Cursor;
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(4)
        .expect("fuzz crate sits four levels below the repository root")
        .to_path_buf()
}

fn corpus(target: &str) -> PathBuf {
    let dir = repo_root()
        .join("Vendor/herdr/herdr-ios-ffi/fuzz/corpus")
        .join(target);
    fs::create_dir_all(&dir).expect("corpus dir");
    dir
}

fn write_if_absent(path: &PathBuf, bytes: &[u8]) {
    if !path.exists() {
        fs::write(path, bytes).expect("seed write");
    }
}

fn pane() -> PaneSurfacePane {
    let rect = SurfaceRect {
        x: 0,
        y: 0,
        width: 1,
        height: 1,
    };
    PaneSurfacePane {
        pane_id: "p1".into(),
        content_revision: 2,
        rect,
        inner_rect: rect,
        scrollbar_rect: None,
        scroll: None,
        focused: true,
        mouse_reporting: false,
        sgr_pixel_mouse: false,
        alternate_screen_active: false,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn cell(symbol: &str) -> CellData {
    CellData {
        symbol: symbol.into(),
        fg: 0,
        bg: 0,
        modifier: 0,
        skip: false,
        hyperlink: None,
    }
}

fn patch_payload(
    projection_revision: u64,
    base: u64,
    next: u64,
    cells: Vec<CellData>,
    cursor: Option<CursorState>,
) -> Vec<u8> {
    let patch = PaneSurfacePatch {
        boot_id: "boot".into(),
        projection_revision,
        base_surface_revision: base,
        surface_revision: next,
        rows: vec![PaneSurfacePatchRow { x: 0, y: 0, cells }],
        panes: vec![pane()],
        cursor,
    };
    let mut buffer = Cursor::new(Vec::new());
    write_message(&mut buffer, &ServerMessage::PaneSurfacePatch(patch)).expect("patch encodes");
    let framed = buffer.into_inner();
    // patch_apply decodes the payload directly: strip the 4-byte length.
    framed[4..].to_vec()
}

fn main() {
    let root = repo_root();
    let vendor_golden = root.join("Vendor/herdr/herdr-protocol/tests/fixtures/golden");
    let fixtures_golden = root.join("Fixtures/herdr/golden");
    let protocol_fixtures = root.join("Vendor/herdr/herdr-protocol/tests/fixtures");

    // length_parse: complete framed server vectors (welcome, snapshot
    // carrier, every frozen variant) plus the app-side golden frames.
    let length_dir = corpus("length_parse");
    for entry in fs::read_dir(&vendor_golden).expect("vendor golden dir") {
        let path = entry.expect("dir entry").path();
        let is_server_frame = path
            .file_stem()
            .is_some_and(|stem| stem.to_string_lossy().starts_with("server"));
        if path.extension().is_some_and(|ext| ext == "bin") && is_server_frame {
            let bytes = fs::read(&path).expect("golden read");
            write_if_absent(&length_dir.join(path.file_name().unwrap()), &bytes);
        }
    }
    for name in [
        "welcome-gen99",
        "snapshot-2x2",
        "surface-ack-2x2",
        "surface-2x2",
        "clipboard-osc52-hello",
        "clipboard-osc52-malformed",
    ] {
        let path = fixtures_golden.join(format!("{name}.bin"));
        if path.exists() {
            let bytes = fs::read(&path).expect("fixture read");
            write_if_absent(&length_dir.join(format!("fixture-{name}.bin")), &bytes);
        }
    }

    // bincode_decode: the same vectors without the length prefix.
    let decode_dir = corpus("bincode_decode");
    for entry in fs::read_dir(&vendor_golden).expect("vendor golden dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().is_some_and(|ext| ext == "bin") {
            let bytes = fs::read(&path).expect("golden read");
            if bytes.len() > 4 {
                write_if_absent(&decode_dir.join(path.file_name().unwrap()), &bytes[4..]);
            }
        }
    }

    // endpoint_json: the stable JSON carriers, bounded to keep seeds small.
    let json_dir = corpus("endpoint_json");
    for name in ["endpoint-welcome-v1.json", "endpoint-snapshot-v1.json"] {
        let bytes = fs::read(protocol_fixtures.join(name)).expect("fixture read");
        write_if_absent(&json_dir.join(name), &bytes);
    }
    let surface_json = fs::read(fixtures_golden.join("surface-2x2.json")).expect("fixture read");
    write_if_absent(
        &json_dir.join("surface-2x2.truncated.json"),
        &surface_json[..surface_json.len().min(8192)],
    );
    write_if_absent(
        &json_dir.join("welcome-error.json"),
        br#"{"generation":1,"server_version":"0.9.0","snapshot_codec":"shell.snapshot.v1","surface_codec":"shell.surface.v1","input_codec":"shell.input.semantic.v1","blob_codec":"shell.blob.v1","methods":[],"capabilities":[],"error":{"code":"rejected","message":"nope"}}"#,
    );

    // patch_apply: coherent and near-miss patch payloads against the
    // committed revision-2 surface (boot "boot", 1x1 pane "p1").
    let patch_dir = corpus("patch_apply");
    let valid = patch_payload(2, 2, 3, vec![cell("z")], None);
    write_if_absent(&patch_dir.join("valid-rev2-to-3.patch"), &valid);
    let wrong_boot = {
        let mut bytes = valid.clone();
        // bincode strings are length-prefixed; "boot" (4 bytes) sits at a
        // stable offset after the enum tag — flip a byte in the payload.
        if let Some(index) = bytes.windows(4).position(|w| w == b"boot") {
            bytes[index] = b'B';
        }
        bytes
    };
    write_if_absent(&patch_dir.join("wrong-boot.patch"), &wrong_boot);
    let cursor = CursorState {
        x: 0,
        y: 0,
        visible: true,
        shape: 0,
    };
    let with_cursor = patch_payload(2, 2, 3, vec![cell("y")], Some(cursor));
    write_if_absent(&patch_dir.join("valid-with-cursor.patch"), &with_cursor);
    let stale_base = patch_payload(2, 1, 3, vec![cell("s")], None);
    write_if_absent(&patch_dir.join("stale-base.patch"), &stale_base);

    println!(
        "seeds: length_parse={} bincode_decode={} endpoint_json={} patch_apply={} (max frame {} bytes)",
        fs::read_dir(&length_dir).map(|d| d.count()).unwrap_or(0),
        fs::read_dir(&decode_dir).map(|d| d.count()).unwrap_or(0),
        fs::read_dir(&json_dir).map(|d| d.count()).unwrap_or(0),
        fs::read_dir(&patch_dir).map(|d| d.count()).unwrap_or(0),
        MAX_FRAME_SIZE,
    );
}
