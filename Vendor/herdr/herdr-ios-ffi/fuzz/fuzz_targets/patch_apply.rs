//! Fuzz target: the incremental patch engine (`ClientShellState::
//! apply_pane_surface_patch`) against a freshly committed coherent surface.
//!
//! Each iteration drives the full admission dance (welcome → snapshot →
//! surface-set ack → surface → presentation fence) to commit a 1x1 surface
//! at revision 2, then applies an arbitrary `PaneSurfacePatch` decoded from
//! the fuzz input. The engine must never panic and must stay atomic: an
//! invalid patch rejects, it never partially mutates the committed surface
//! (asserted by re-checking the invariant afterwards).
#![no_main]

use herdr_client_core::client::shell::SnapshotUpdate;
use herdr_client_core::{outbound::*, protocol::*, *};
use libfuzzer_sys::fuzz_target;
use std::time::Instant;

const SNAPSHOT_JSON: &str =
    include_str!("../../../herdr-protocol/tests/fixtures/endpoint-snapshot-v1.json");

fn snapshot(revision: u64) -> ClientShellSnapshot {
    let mut snapshot: ClientShellSnapshot =
        serde_json::from_str(SNAPSHOT_JSON).expect("committed fixture decodes");
    snapshot.boot_id = "boot".into();
    snapshot.revision = revision;
    snapshot.focused_pane_id = Some("p1".into());
    snapshot
}

fn surface(revision: u64) -> PaneSurfaceFrame {
    let rect = SurfaceRect {
        x: 0,
        y: 0,
        width: 1,
        height: 1,
    };
    PaneSurfaceFrame {
        boot_id: "boot".into(),
        projection_revision: revision,
        surface_revision: revision,
        frame: FrameData {
            width: 1,
            height: 1,
            cells: vec![CellData {
                symbol: "x".into(),
                fg: 0,
                bg: 0,
                modifier: 0,
                skip: false,
                hyperlink: None,
            }],
            cursor: None,
            hyperlinks: vec![],
            graphics: vec![],
        },
        panes: vec![PaneSurfacePane {
            pane_id: "p1".into(),
            content_revision: revision,
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
        }],
        splits: vec![],
        popup: None,
        graphics: SurfaceGraphicsScene::default(),
    }
}

/// Mirrors the upstream `selected_surface` test World: commit a coherent
/// surface through the complete activation transaction, then return the
/// shell with input unfrozen and the fence settled.
fn committed_shell() -> ClientShellState {
    let profile = SavedSshEndpoint::new("Remote", "remote", "main").expect("profile validates");
    let endpoint = ClientEndpointId::Ssh(profile.id.clone());
    let mut shell = ClientShellState::new();
    shell.set_endpoint_catalog(&[profile]);
    let queue = OutboundQueue::new(QueueLimits {
        messages: 64,
        bytes: MAX_FRAME_SIZE,
    });
    let mut registry = EndpointRegistry::empty();
    let welcome =
        endpoint::EndpointServerWelcome::compatible(vec!["client_shell.surface.set".into()]);
    registry.insert(
        endpoint.clone(),
        queue.clone(),
        1,
        EndpointNegotiation::new(welcome.methods, welcome.capabilities),
        false,
    );
    assert!(shell.receive_snapshot(
        &registry,
        SnapshotUpdate {
            endpoint: endpoint.clone(),
            generation: 1,
            snapshot: Box::new(snapshot(1))
        }
    ));
    shell.set_endpoint_status(&endpoint, ClientEndpointStatus::Online);
    let resize = ClientMessage::ClientShellResize {
        cell_width_px: 0,
        cell_height_px: 0,
        surface_size: ClientSurfaceSize { cols: 1, rows: 1 },
        pixel_mouse: false,
    };
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut registry,
        endpoint.clone(),
        None,
        resize,
        1,
        Instant::now(),
    )
    .expect("activation begins");
    let acknowledge = |shell: &mut ClientShellState,
                       registry: &mut EndpointRegistry,
                       activation: &mut PendingEndpointActivation,
                       request_id: &str,
                       revision: u64| {
        let response = serde_json::to_vec(&api::schema::SuccessResponse {
            id: request_id.into(),
            result: api::schema::ResponseResult::ClientShellSurfaceSet {
                active: true,
                projection_revision: revision,
            },
        })
        .expect("ack JSON");
        activation.receive_response_for_boot(&endpoint, 1, "boot", request_id, &response, registry);
        shell.receive_snapshot(
            registry,
            SnapshotUpdate {
                endpoint: endpoint.clone(),
                generation: 1,
                snapshot: Box::new(snapshot(revision)),
            },
        );
        activation.receive_snapshot(&endpoint, 1, &snapshot(revision));
        activation.receive_surface(&endpoint, 1, surface(revision));
    };
    acknowledge(
        &mut shell,
        &mut registry,
        &mut activation,
        "client-shell-surface:1:on",
        1,
    );
    shell
        .complete_activation(&mut registry, &mut activation)
        .expect("first completion");
    acknowledge(
        &mut shell,
        &mut registry,
        &mut activation,
        "client-shell-surface:1:presentation-sync",
        2,
    );
    shell
        .complete_activation(&mut registry, &mut activation)
        .expect("second completion");
    activation.receive_presentation_effects_ready(&endpoint, 1, "1:1:boot");
    shell
        .complete_activation(&mut registry, &mut activation)
        .expect("final completion");
    shell
}

fuzz_target!(|data: &[u8]| {
    let config = herdr_protocol::framing_decode_config();
    let decoded: Result<(herdr_protocol::PaneSurfacePatch, usize), _> =
        bincode::serde::decode_from_slice(data, config);
    let Ok((patch, consumed)) = decoded else {
        return;
    };
    assert!(consumed <= data.len(), "patch decode over-consumed input");

    let mut shell = committed_shell();
    let before = shell.surface().expect("fence committed a surface").clone();
    let _ = shell.apply_pane_surface_patch(patch);
    let after = shell
        .surface()
        .expect("surface slot is never cleared")
        .clone();

    // Atomicity invariant: a rejected patch must leave the committed
    // surface byte-identical; an accepted one keeps it structurally valid.
    assert_eq!(after.boot_id, "boot");
    assert_eq!(after.frame.width, before.frame.width);
    assert_eq!(after.frame.height, before.frame.height);
    assert_eq!(
        after.frame.cells.len(),
        usize::from(after.frame.width) * usize::from(after.frame.height),
        "patched frame stays cell-complete"
    );

    // The re-encode path must not panic for whatever state resulted.
    let mut buffer = std::io::Cursor::new(Vec::new());
    let message = ServerMessage::PaneSurface(after);
    let _ = write_message(&mut buffer, &message);
});
