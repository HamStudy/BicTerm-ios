// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (495:628), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn negotiated_remote_health_probe_expires_the_connection() {
    let mut registry = EndpointRegistry::new(
        FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            error: None,
        },
        1,
        negotiation(),
    );
    let ssh_id = ClientEndpointId::Ssh(profile());
    let sent = Arc::new(Mutex::new(Vec::new()));
    registry.insert(
        ssh_id.clone(),
        FakeTransport {
            sent: sent.clone(),
            error: None,
        },
        2,
        negotiation(),
        false,
    );
    let now = Instant::now();
    registry.tick_health(now + crate::client::endpoint::health::HEARTBEAT_INTERVAL);
    assert!(matches!(
        sent.lock().unwrap().as_slice(),
        [ClientMessage::EndpointControl { kind, .. }]
            if kind == crate::protocol::endpoint::HEALTH_PING_KIND
    ));

    registry.tick_health(
        now + crate::client::endpoint::health::HEARTBEAT_INTERVAL
            + crate::client::endpoint::health::HEARTBEAT_TIMEOUT,
    );
    assert!(registry.connection(&ssh_id).is_none());
    assert_eq!(registry.take_failures()[0].kind, io::ErrorKind::TimedOut);
}

#[test]
fn a_ready_endpoint_can_stay_connected_after_the_initial_deadline() {
    let mut registry = EndpointRegistry::new(
        FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            error: None,
        },
        1,
        negotiation(),
    );
    let ssh_id = ClientEndpointId::Ssh(profile());
    registry.insert(
        ssh_id.clone(),
        FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            error: None,
        },
        2,
        negotiation(),
        false,
    );
    let now = Instant::now();
    registry.mark_ready(&ssh_id, 2);
    registry.received(
        &ssh_id,
        2,
        now + crate::client::endpoint::health::HEARTBEAT_INTERVAL,
    );
    registry.tick_health(now + crate::client::endpoint::health::HEARTBEAT_TIMEOUT);
    assert!(registry.connection(&ssh_id).is_some());
}

#[test]
fn negotiated_surface_interest_requires_capability_and_method() {
    assert!(negotiation().supports_surface_interest());
    assert!(negotiation().supports_health_check());
    assert!(
        !EndpointNegotiation::new(vec!["client_shell.surface.set".into()], Vec::new())
            .supports_surface_interest()
    );
    assert!(!EndpointNegotiation::new(
        Vec::new(),
        vec![crate::protocol::endpoint::SURFACE_INTEREST_CAPABILITY.into()]
    )
    .supports_surface_interest());
    assert!(!EndpointNegotiation::new(
        vec!["client_shell.surface.set".into()],
        vec![crate::protocol::endpoint::SURFACE_INTEREST_CAPABILITY.into()]
    )
    .supports_surface_interest());
}

#[test]
fn dropping_registry_detaches_every_connected_endpoint() {
    let local_sent = Arc::new(Mutex::new(Vec::new()));
    let remote_sent = Arc::new(Mutex::new(Vec::new()));
    let mut registry = EndpointRegistry::new(
        FakeTransport {
            sent: local_sent.clone(),
            error: None,
        },
        1,
        negotiation(),
    );
    registry.insert(
        ClientEndpointId::Ssh(profile()),
        FakeTransport {
            sent: remote_sent.clone(),
            error: None,
        },
        2,
        negotiation(),
        false,
    );

    drop(registry);

    assert!(matches!(
        local_sent.lock().unwrap().as_slice(),
        [ClientMessage::Detach]
    ));
    assert!(matches!(
        remote_sent.lock().unwrap().as_slice(),
        [ClientMessage::Detach]
    ));
}

#[test]
fn stale_generations_are_rejected() {
    let registry = EndpointRegistry::new(
        FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            error: None,
        },
        7,
        negotiation(),
    );
    assert!(registry.accepts(&test_source(), 7));
    assert!(!registry.accepts(&test_source(), 6));
}

use super::*;
