use herdr_client_core::handshake::{HandshakeError, PendingHandshake};
use herdr_client_core::protocol::{endpoint::*, ClientSurfaceSize, ServerMessage};
use herdr_client_core::*;
use std::time::{Duration, Instant};

fn hello() -> EndpointClientHello {
    EndpointClientHello {
        generation: 1,
        cell_width_px: 0,
        cell_height_px: 0,
        surface_size: ClientSurfaceSize { cols: 80, rows: 24 },
        pixel_mouse: false,
        direct_graphics: false,
        endpoint_keybindings: false,
        mouse_capture: false,
        surface_active: false,
        snapshot_codecs: vec![SNAPSHOT_CODEC_V1.into()],
        surface_codecs: vec![SURFACE_CODEC_V1.into()],
        input_codecs: vec![INPUT_CODEC_V1.into()],
        blob_codecs: vec![BLOB_CODEC_V1.into()],
    }
}

#[test]
fn admission_rejects_missing_presentation_fence() {
    // Given
    let now = Instant::now();
    let (pending, _) = PendingHandshake::begin(&hello(), now).unwrap();
    let mut welcome = EndpointServerWelcome::compatible(vec!["client_shell.surface.set".into()]);
    welcome
        .capabilities
        .retain(|capability| capability != PRESENTATION_EFFECTS_FENCE_CAPABILITY);
    // When
    let result = pending.receive(
        ServerMessage::EndpointControl {
            kind: ENDPOINT_WELCOME_KIND.into(),
            data: serde_json::to_string(&welcome).unwrap(),
        },
        now,
    );
    // Then
    assert_eq!(result, Err(HandshakeError::Incompatible));
}

#[test]
fn remote_handshake_keeps_the_long_timeout() {
    // Given
    let now = Instant::now();
    let (pending, _) = PendingHandshake::begin(&hello(), now).unwrap();
    let welcome = EndpointServerWelcome::compatible(vec!["client_shell.surface.set".into()]);
    // When
    let result = pending.receive(
        ServerMessage::EndpointControl {
            kind: ENDPOINT_WELCOME_KIND.into(),
            data: serde_json::to_string(&welcome).unwrap(),
        },
        now + Duration::from_secs(59),
    );
    // Then
    assert!(result.unwrap().supports_health_check());
}

#[test]
fn remote_handshake_times_out_at_deadline_without_private_fallback() {
    // Given
    let now = Instant::now();
    let (pending, _) = PendingHandshake::begin(&hello(), now).unwrap();
    // When
    let result = pending.receive(
        ServerMessage::TerminalBell { count: 1 },
        now + Duration::from_secs(60),
    );
    // Then
    assert_eq!(result, Err(HandshakeError::TimedOut));
}

#[test]
fn retrying_one_machine_does_not_reconnect_the_healthy_machine() {
    // Given
    let now = Instant::now();
    let profiles = [
        SavedSshEndpoint::new("A", "a", "main").unwrap(),
        SavedSshEndpoint::new("B", "b", "main").unwrap(),
    ];
    let mut supervisor = EndpointSupervisors::new(&profiles, now);
    let attempts = supervisor.poll_due(now, 2);
    assert_eq!(attempts.len(), 2);
    supervisor.record_status(&attempts[0], ClientEndpointStatus::Reconnecting, now);
    supervisor.record_status(&attempts[1], ClientEndpointStatus::Online, now);
    // When
    let retries = supervisor.poll_due(now + Duration::from_millis(500), 2);
    // Then
    assert_eq!(retries.len(), 1);
    assert_eq!(retries[0].endpoint, attempts[0].endpoint);
    assert!(retries[0].generation > attempts[0].generation);
    assert!(!supervisor.record_status(&attempts[0], ClientEndpointStatus::Online, now));
}

#[test]
fn removing_a_profile_retires_its_inflight_generation() {
    // Given
    let now = Instant::now();
    let profile = SavedSshEndpoint::new("A", "a", "main").unwrap();
    let mut supervisor = EndpointSupervisors::new(&[profile], now);
    let attempts = supervisor.poll_due(now, 1);
    supervisor.reconcile_profiles(&[], now);
    // When
    let accepted = supervisor.record_status(&attempts[0], ClientEndpointStatus::Online, now);
    // Then
    assert!(!accepted);
    assert!(supervisor
        .poll_due(now + Duration::from_secs(30), 2)
        .is_empty());
}

#[test]
fn bounded_parallelism_does_not_launch_extra_attempts() {
    // Given
    let now = Instant::now();
    let profiles = [
        SavedSshEndpoint::new("A", "a", "main").unwrap(),
        SavedSshEndpoint::new("B", "b", "main").unwrap(),
    ];
    let mut supervisor = EndpointSupervisors::new(&profiles, now);
    supervisor.poll_due(now, 1);
    // When
    let attempts = supervisor.poll_due(now, 1);
    // Then
    assert!(attempts.is_empty());
}

#[test]
fn catalog_rejects_duplicate_profile_identity_at_decode() {
    // Given
    let mut catalog = EndpointCatalog::default();
    catalog.add_ssh("A", "a", "main").unwrap();
    catalog.ssh.push(catalog.ssh[0].clone());
    let bytes = serde_json::to_vec(&catalog).unwrap();
    // When
    let result = EndpointCatalog::from_json(&bytes);
    // Then
    assert!(result
        .unwrap_err()
        .contains("duplicate endpoint profile id"));
}

#[test]
fn catalog_disable_returns_selection_to_home() {
    // Given
    let mut catalog = EndpointCatalog::default();
    let id = catalog.add_ssh("A", "a", "main").unwrap();
    assert!(catalog.select_ssh(&id));
    // When
    catalog.set_enabled(&id, false);
    // Then
    assert_eq!(catalog.selected_profile, None);
    assert!(!catalog.select_ssh(&id));
}

#[test]
fn neutral_home_cannot_own_a_transport() {
    // Given
    let mut registry = EndpointRegistry::empty();
    let queue =
        herdr_client_core::outbound::OutboundQueue::new(herdr_client_core::outbound::QueueLimits {
            messages: 1,
            bytes: 64,
        });
    // When
    let inserted = registry.insert(
        ClientEndpointId::Home,
        queue,
        1,
        EndpointNegotiation::default(),
        true,
    );
    // Then
    assert!(!inserted);
    assert!(registry.connection(&ClientEndpointId::Home).is_none());
}
