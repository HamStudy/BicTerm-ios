// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (644:815), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn host_focus_change_restarts_an_issued_presentation_effects_fence() {
    let (_shell, mut endpoints, _local_sent, remote_sent) = shell_and_registry();
    let mut activation = machine();
    activation.phase = ActivationPhase::AwaitingPresentationEffects {
        lease: lease(endpoint(), 7, "remote-boot"),
        token: "old-token".into(),
        ready: false,
        completion: Box::new(ActivationCompletion::Activated),
    };

    activation.update_host_focus(false, &mut endpoints).unwrap();

    assert!(matches!(
        activation.phase,
        ActivationPhase::SynchronizingPresentation { .. }
    ));
    assert_eq!(
        activation.receive_presentation_effects_ready(&endpoint(), 7, "old-token"),
        SurfaceActivationProgress::Stale
    );
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

#[test]
fn source_release_rejection_restores_the_source_coherently() {
    let (shell, mut endpoints, local_sent, _remote_sent) = shell_and_registry();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        13,
        Instant::now(),
    )
    .unwrap();
    assert_eq!(
        activation.receive_response(
            &test_source(),
            1,
            "client-shell-surface:13:off",
            &failure("client-shell-surface:13:off", "source rejected release"),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Rejected {
            message: "source rejected release".into(),
            source_release_rejected: true,
        }
    );
    assert_eq!(
        activation.rollback(&mut endpoints, "source rejected release".into(), true),
        ActivationRollback::Pending
    );
    assert_eq!(endpoints.active_id(), &test_source());
    assert!(!endpoints.active_surface_available());
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
fn source_release_timeout_starts_an_acknowledged_source_restore() {
    let (shell, mut endpoints, local_sent, _remote_sent) = shell_and_registry();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        14,
        Instant::now(),
    )
    .unwrap();
    assert_eq!(
        activation.rollback(&mut endpoints, "source release timed out".into(), false),
        ActivationRollback::Pending
    );
    let sent = local_sent.lock().unwrap();
    assert_eq!(
        sent.iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![false, true]
    );
    assert!(activation.accepts_response(
        &test_source(),
        1,
        "local-boot",
        "client-shell-surface:14:rollback-source-on"
    ));
}

#[test]
fn resize_invalidates_already_recorded_surface_evidence() {
    let (_shell, mut endpoints, _local_sent, _remote_sent) = shell_and_registry();
    let mut activation = machine();
    assert_eq!(
        activation.receive_snapshot(&endpoint(), 7, &test_snapshot("remote-boot", 1)),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&endpoint(), 7, surface("remote-boot", 1, "pane")),
        SurfaceActivationProgress::Ready
    );
    let resize = crate::protocol::ClientMessage::ClientShellResize {
        cell_width_px: 9,
        cell_height_px: 17,
        surface_size: crate::protocol::ClientSurfaceSize {
            cols: 100,
            rows: 30,
        },
        pixel_mouse: true,
    };
    activation.update_resize(resize, &mut endpoints).unwrap();
    assert_eq!(activation.progress(), SurfaceActivationProgress::Pending);
}

#[test]
fn resize_during_activation_reaches_the_pending_target() {
    let (shell, mut endpoints, _local_sent, remote_sent) = shell_and_registry();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        15,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:15:off",
        &surface_success("client-shell-surface:15:off", false, 1),
        &mut endpoints,
    );
    let resized = crate::protocol::ClientMessage::ClientShellResize {
        cell_width_px: 9,
        cell_height_px: 17,
        surface_size: crate::protocol::ClientSurfaceSize {
            cols: 100,
            rows: 30,
        },
        pixel_mouse: true,
    };
    activation
        .update_resize(resized.clone(), &mut endpoints)
        .unwrap();
    assert_eq!(remote_sent.lock().unwrap().last(), Some(&resized));
    assert_eq!(
        activation.receive_surface(&endpoint(), 7, surface("remote-boot", 1, "pane")),
        SurfaceActivationProgress::Pending,
        "a surface for the prior geometry cannot commit"
    );
}

use super::*;
