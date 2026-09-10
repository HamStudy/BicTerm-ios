// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (398:493), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn endpoint_failures_do_not_remove_other_connections() {
    let local_sent = Arc::new(Mutex::new(Vec::new()));
    let mut registry = EndpointRegistry::new(
        FakeTransport {
            sent: local_sent.clone(),
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
            error: Some(io::ErrorKind::BrokenPipe),
        },
        2,
        negotiation(),
        true,
    );
    assert!(registry.set_active(&ssh_id));

    assert_eq!(
        registry.send(&ClientMessage::ClientShellFocus { focused: true }),
        EndpointSendOutcome::NotSent
    );
    assert!(registry.connection(&ssh_id).is_none());
    assert!(registry.connection(&test_source()).is_some());
    assert_eq!(registry.take_failures()[0].endpoint_id, ssh_id);

    assert!(registry.set_active(&test_source()));
    assert_eq!(
        registry.send(&ClientMessage::ClientShellFocus { focused: true }),
        EndpointSendOutcome::Sent
    );
    assert_eq!(local_sent.lock().unwrap().len(), 1);
}

#[test]
fn reconnecting_active_identity_does_not_count_as_an_active_surface() {
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
        true,
    );
    assert!(registry.set_active(&ssh_id));
    assert!(registry.active_surface_available());
    registry.disconnect(&ssh_id);
    registry.insert(
        ssh_id,
        FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            error: None,
        },
        3,
        negotiation(),
        false,
    );
    assert!(!registry.active_surface_available());
}

#[test]
fn recovered_source_is_remote_and_uses_health_probes() {
    let mut registry = EndpointRegistry::empty();
    let sent = Arc::new(Mutex::new(Vec::new()));
    registry.insert(
        test_source(),
        FakeTransport {
            sent: sent.clone(),
            error: None,
        },
        2,
        negotiation(),
        false,
    );
    registry.tick_health(Instant::now() + std::time::Duration::from_secs(300));
    assert!(registry.connection(&test_source()).is_none());
    assert!(sent.lock().unwrap().is_empty());
    assert_eq!(registry.take_failures().len(), 1);
}

use super::*;
