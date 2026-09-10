// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (816:977), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn rapid_a_to_b_to_a_restores_source_before_a_fresh_latest_epoch() {
    let (mut shell, mut endpoints, local_sent, remote_sent) = shell_and_registry();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        20,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:20:off",
        &surface_success("client-shell-surface:20:off", false, 1),
        &mut endpoints,
    );

    // The latest A-qualified target replaces B while B may already have accepted target-on.
    assert_eq!(
        activation.supersede(
            test_source(),
            Some(crate::client::shell::ClientEndpointFocusTarget::Pane(
                "local-pane".into(),
            )),
            &mut endpoints,
        ),
        ActivationRollback::Pending
    );
    assert_eq!(
        remote_sent
            .lock()
            .unwrap()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![true, false],
        "B is released before A can be restored"
    );
    assert_eq!(
        activation.receive_surface(&endpoint(), 7, surface("remote-boot", 2, "pane")),
        SurfaceActivationProgress::Stale,
        "delayed B activation evidence cannot satisfy A restoration"
    );
    let _ = activation.receive_response(
        &endpoint(),
        7,
        "client-shell-surface:20:rollback-target-off",
        &surface_success("client-shell-surface:20:rollback-target-off", false, 1),
        &mut endpoints,
    );
    assert_eq!(
        local_sent
            .lock()
            .unwrap()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![false, true],
        "source restoration is acknowledged rather than racing target ownership"
    );
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:20:rollback-source-on",
        &surface_success("client-shell-surface:20:rollback-source-on", true, 2),
        &mut endpoints,
    );
    let local_snapshot = test_snapshot("local-boot", 2);
    shell.set_endpoint_snapshot_for_generation(&test_source(), 1, Box::new(local_snapshot.clone()));
    assert_eq!(
        activation.receive_snapshot(&test_source(), 1, &local_snapshot),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&test_source(), 1, surface("local-boot", 2, "pane")),
        SurfaceActivationProgress::Ready
    );
    assert!(matches!(
        activation.complete(&mut shell, &mut endpoints),
        Ok(ActivationCompletion::AwaitingPresentationSync {
            endpoint,
            ..
        }) if endpoint == test_source()
    ));
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:20:presentation-sync",
        &surface_success("client-shell-surface:20:presentation-sync", true, 3),
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
        activation.receive_presentation_effects_ready(&test_source(), 1, "20:1:local-boot"),
        SurfaceActivationProgress::Ready
    );
    assert!(matches!(
        activation.complete(&mut shell, &mut endpoints),
        Ok(ActivationCompletion::RestoredSource {
            successor: Some(EndpointActivationIntent {
                endpoint_id: successor_endpoint,
                ..
            }),
            ..
        }) if successor_endpoint == test_source()
    ));
    assert_eq!(endpoints.active_id(), &test_source());

    // Runtime queues this successor with force=true, so even source==target receives a new
    // activation epoch only after restoration committed.
    let _fresh_epoch = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        test_source(),
        Some(crate::client::shell::ClientEndpointFocusTarget::Pane(
            "local-pane".into(),
        )),
        resize(),
        21,
        Instant::now(),
    )
    .unwrap();
    assert!(local_sent.lock().unwrap().iter().any(|message| {
        matches!(
            message,
            crate::protocol::ClientMessage::ClientShellEndpointRequest { request, .. }
                if serde_json::from_str::<crate::api::schema::Request>(request)
                    .is_ok_and(|request| request.id == "client-shell-surface:21:on")
        )
    }));
}

use super::*;
