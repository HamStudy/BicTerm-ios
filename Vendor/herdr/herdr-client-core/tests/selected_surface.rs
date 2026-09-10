use herdr_client_core::client::shell::*;
use herdr_client_core::{outbound::*, protocol::*, *};
use std::time::Instant;

struct World {
    shell: ClientShellState,
    registry: EndpointRegistry,
    queue: OutboundQueue,
    endpoint: ClientEndpointId,
    activation: PendingEndpointActivation,
}

fn snapshot(revision: u64) -> ClientShellSnapshot {
    let mut snapshot: ClientShellSnapshot = serde_json::from_str(include_str!(
        "../../herdr-protocol/tests/fixtures/endpoint-snapshot-v1.json"
    ))
    .unwrap();
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

impl World {
    fn begin() -> Self {
        let profile = SavedSshEndpoint::new("Remote", "remote", "main").unwrap();
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
        let activation = PendingEndpointActivation::begin(
            &shell,
            &mut registry,
            endpoint.clone(),
            None,
            resize,
            1,
            Instant::now(),
        )
        .unwrap();
        Self {
            shell,
            registry,
            queue,
            endpoint,
            activation,
        }
    }

    fn drain(&self) -> Vec<ClientMessage> {
        std::iter::from_fn(|| self.queue.drain_frame().unwrap())
            .map(|frame| read_message(&mut frame.as_slice(), MAX_FRAME_SIZE).unwrap())
            .collect()
    }

    fn acknowledge(&mut self, request_id: &str, revision: u64) {
        let response = serde_json::to_vec(&api::schema::SuccessResponse {
            id: request_id.into(),
            result: api::schema::ResponseResult::ClientShellSurfaceSet {
                active: true,
                projection_revision: revision,
            },
        })
        .unwrap();
        self.activation.receive_response_for_boot(
            &self.endpoint,
            1,
            "boot",
            request_id,
            &response,
            &mut self.registry,
        );
        self.shell.receive_snapshot(
            &self.registry,
            SnapshotUpdate {
                endpoint: self.endpoint.clone(),
                generation: 1,
                snapshot: Box::new(snapshot(revision)),
            },
        );
        self.activation
            .receive_snapshot(&self.endpoint, 1, &snapshot(revision));
        assert_eq!(
            self.activation
                .receive_surface(&self.endpoint, 1, surface(revision)),
            SurfaceActivationProgress::Ready
        );
    }

    fn input(&self) -> PaneInput {
        PaneInput {
            target: QualifiedPane {
                endpoint: self.endpoint.clone(),
                generation: 1,
                boot_id: "boot".into(),
                pane_id: "p1".into(),
            },
            event: ClientPaneInputEvent::Paste("hello".into()),
        }
    }

    fn ready() -> Self {
        let mut world = Self::begin();
        world.acknowledge("client-shell-surface:1:on", 1);
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap();
        world.acknowledge("client-shell-surface:1:presentation-sync", 2);
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap();
        world
            .activation
            .receive_presentation_effects_ready(&world.endpoint, 1, "1:1:boot");
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap();
        world.drain();
        world
    }
}

#[path = "support/activation_flow.rs"]
mod activation_flow;

#[test]
fn invalid_patch_is_atomic_and_leaves_the_committed_surface_unchanged() {
    // Given
    let mut world = World::ready();
    let before = world.shell.surface().unwrap().clone();
    let patch = PaneSurfacePatch {
        boot_id: "boot".into(),
        projection_revision: 2,
        base_surface_revision: 2,
        surface_revision: 3,
        rows: vec![PaneSurfacePatchRow {
            x: 1,
            y: 0,
            cells: before.frame.cells.clone(),
        }],
        panes: before.panes.clone(),
        cursor: None,
    };
    // When
    let result = world.shell.apply_pane_surface_patch(patch);
    // Then
    assert!(matches!(result, ClientPaneSurfacePatchOutcome::Rejected));
    assert_eq!(world.shell.surface(), Some(&before));
}

#[test]
fn valid_patch_advances_revision_and_replaces_terminal_cells() {
    // Given
    let mut world = World::ready();
    let before = world.shell.surface().unwrap();
    let mut cells = before.frame.cells.clone();
    cells[0].symbol = "changed".into();
    let patch = PaneSurfacePatch {
        boot_id: "boot".into(),
        projection_revision: 2,
        base_surface_revision: 2,
        surface_revision: 3,
        rows: vec![PaneSurfacePatchRow { x: 0, y: 0, cells }],
        panes: before.panes.clone(),
        cursor: None,
    };
    // When
    let result = world.shell.apply_pane_surface_patch(patch);
    // Then
    assert!(matches!(result, ClientPaneSurfacePatchOutcome::Applied));
    assert_eq!(world.shell.surface().unwrap().surface_revision, 3);
    assert_eq!(
        world.shell.surface().unwrap().frame.cells[0].symbol,
        "changed"
    );
}
