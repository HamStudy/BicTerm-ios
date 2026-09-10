// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (978:1139), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn disconnected_committed_source_does_not_block_switching_to_a_live_endpoint() {
    let (mut shell, mut endpoints, local_sent, _remote_sent) = shell_and_registry();
    let disconnected = endpoint();
    endpoints.set_surface_active(&test_source(), false);
    endpoints.set_surface_active(&disconnected, true);
    assert!(endpoints.set_active(&disconnected));
    assert!(shell.activate_endpoint_projection(&disconnected));
    endpoints.disconnect(&disconnected);

    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        test_source(),
        None,
        resize(),
        22,
        Instant::now(),
    )
    .unwrap();
    assert_eq!(activation.source_command_lane(), None);
    assert_eq!(
        local_sent
            .lock()
            .unwrap()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![true],
        "there is no unavailable source release to await"
    );

    assert_eq!(
        activation.receive_response(
            &test_source(),
            1,
            "client-shell-surface:22:on",
            &surface_success("client-shell-surface:22:on", true, 2),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Pending
    );
    let snapshot = test_snapshot("local-boot", 2);
    shell.set_endpoint_snapshot_for_generation(&test_source(), 1, Box::new(snapshot.clone()));
    assert_eq!(
        activation.receive_snapshot(&test_source(), 1, &snapshot),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&test_source(), 1, surface("local-boot", 2, "pane")),
        SurfaceActivationProgress::Ready
    );
    assert!(matches!(
        activation.complete(&mut shell, &mut endpoints),
        Ok(ActivationCompletion::AwaitingPresentationSync {
            previous,
            endpoint,
        }) if previous == disconnected && endpoint == test_source()
    ));
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:22:presentation-sync",
        &surface_success("client-shell-surface:22:presentation-sync", true, 3),
        &mut endpoints,
    );
    let sync_snapshot = test_snapshot("local-boot", 3);
    shell.set_endpoint_snapshot_for_generation(&test_source(), 1, Box::new(sync_snapshot.clone()));
    let _ = activation.receive_snapshot(&test_source(), 1, &sync_snapshot);
    assert_eq!(
        activation.receive_surface(&test_source(), 1, surface("local-boot", 3, "pane")),
        SurfaceActivationProgress::Ready
    );
    assert_eq!(
        activation.complete(&mut shell, &mut endpoints),
        Ok(ActivationCompletion::AwaitingPresentationEffects)
    );
    assert_eq!(
        activation.receive_presentation_effects_ready(&test_source(), 1, "22:1:local-boot"),
        SurfaceActivationProgress::Ready
    );
    assert_eq!(
        activation.complete(&mut shell, &mut endpoints),
        Ok(ActivationCompletion::Activated)
    );
    assert_eq!(endpoints.active_id(), &test_source());
    assert_ne!(endpoints.active_id(), &disconnected);
}

#[test]
fn rollback_keeps_the_latest_intent_even_when_it_returns_to_the_target() {
    let (shell, mut endpoints, _local_sent, _remote_sent) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        None,
        resize(),
        23,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:23:off",
        &surface_success("client-shell-surface:23:off", false, 1),
        &mut endpoints,
    );
    assert_eq!(
        activation.supersede(
            test_source(),
            Some(crate::client::shell::ClientEndpointFocusTarget::Pane(
                "local-pane".into()
            )),
            &mut endpoints,
        ),
        ActivationRollback::Pending
    );
    assert!(!activation.can_retarget(&target));
    assert_eq!(
        activation.supersede(
            target.clone(),
            Some(crate::client::shell::ClientEndpointFocusTarget::Pane(
                "remote-pane".into()
            )),
            &mut endpoints,
        ),
        ActivationRollback::Pending
    );
    assert_eq!(
        activation.successor,
        Some(EndpointActivationIntent {
            endpoint_id: target,
            target: Some(crate::client::shell::ClientEndpointFocusTarget::Pane(
                "remote-pane".into()
            )),
        })
    );
}

use super::*;
