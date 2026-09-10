// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (1140:1305), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn unacknowledged_target_release_closes_target_before_restoring_source() {
    let (shell, mut endpoints, local_sent, _remote_sent) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        None,
        resize(),
        24,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:24:off",
        &surface_success("client-shell-surface:24:off", false, 1),
        &mut endpoints,
    );
    assert_eq!(
        activation.rollback(&mut endpoints, "target activation timed out".into(), false),
        ActivationRollback::Pending
    );
    assert_eq!(
        activation.rollback(&mut endpoints, "target release timed out".into(), false),
        ActivationRollback::Pending
    );
    assert!(endpoints.connection(&target).is_none());
    let failures = endpoints.take_failures();
    assert_eq!(
        failures.len(),
        1,
        "rollback revocation must reach the reconnect owner"
    );
    assert_eq!(failures[0].endpoint_id, target);
    assert_eq!(failures[0].generation, 7);
    assert_eq!(failures[0].kind, std::io::ErrorKind::TimedOut);
    assert_eq!(
        local_sent
            .lock()
            .unwrap()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![false, true]
    );
}

#[test]
fn target_loss_at_activation_deadline_restores_source_before_timeout() {
    let (shell, mut endpoints, local_sent, _) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        None,
        resize(),
        30,
        Instant::now(),
    )
    .unwrap();
    activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:30:off",
        &surface_success("client-shell-surface:30:off", false, 1),
        &mut endpoints,
    );
    let now = Instant::now();
    activation.deadline = now;
    assert!(activation.expired(now));
    endpoints.fail(&target, std::io::ErrorKind::UnexpectedEof.into());
    // Match the client timer: apply transport failures before checking phase expiry.
    for failure in endpoints.take_failures() {
        assert_eq!(
            activation.endpoint_disconnected(&mut endpoints, &failure.endpoint_id, failure.message),
            ActivationRollback::Pending
        );
    }
    assert!(matches!(
        activation.phase,
        ActivationPhase::RestoringSource { .. }
    ));
    assert!(!activation.expired(now));
    assert_eq!(
        local_sent
            .lock()
            .unwrap()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![false, true]
    );
}

#[test]
fn losing_local_during_handoff_does_not_revoke_the_healthy_target() {
    for source_released in [false, true] {
        let (shell, mut endpoints, _local_sent, remote_sent) = shell_and_registry();
        let target = endpoint();
        let mut activation = PendingEndpointActivation::begin(
            &shell,
            &mut endpoints,
            target.clone(),
            None,
            resize(),
            29,
            Instant::now(),
        )
        .unwrap();
        if source_released {
            activation.receive_response(
                &test_source(),
                1,
                "client-shell-surface:29:off",
                &surface_success("client-shell-surface:29:off", false, 1),
                &mut endpoints,
            );
        }
        if !source_released {
            activation.deadline = Instant::now() - Duration::from_millis(1);
        }
        endpoints.fail(&test_source(), std::io::ErrorKind::BrokenPipe.into());
        assert_eq!(
            activation.endpoint_disconnected(
                &mut endpoints,
                &test_source(),
                "Local stopped".into()
            ),
            ActivationRollback::Pending
        );
        assert!(!activation.source_available);
        assert!(
            !activation.expired(Instant::now()),
            "starting the healthy target must get a fresh deadline"
        );
        assert!(matches!(
            activation.phase,
            ActivationPhase::ActivatingTarget { .. }
        ));
        assert!(endpoints.connection(&target).is_some());
        assert_eq!(
            remote_sent
                .lock()
                .unwrap()
                .iter()
                .filter_map(surface_set_active)
                .collect::<Vec<_>>(),
            vec![true]
        );
    }
}

#[test]
fn resize_message_preserves_the_latest_surface_dimensions() {
    assert_eq!(
        resize_geometry(&resize()),
        Some(crate::protocol::ClientSurfaceSize { cols: 80, rows: 24 })
    );
}

use super::*;
