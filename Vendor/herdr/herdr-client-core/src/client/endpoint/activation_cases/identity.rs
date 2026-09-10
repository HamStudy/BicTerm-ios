// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (451:643), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn typed_target_ack_sets_a_floor_for_same_boot_activation_evidence() {
    let (shell, mut endpoints, _local_sent, _remote_sent) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        None,
        resize(),
        16,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:16:off",
        &surface_success("client-shell-surface:16:off", false, 1),
        &mut endpoints,
    );
    assert_eq!(
        activation.receive_response(
            &target,
            7,
            "client-shell-surface:16:on",
            &surface_success("client-shell-surface:16:on", true, 4),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_snapshot(&target, 7, &test_snapshot("remote-boot", 3)),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&target, 7, surface("remote-boot", 3, "pane")),
        SurfaceActivationProgress::Pending,
        "a delayed same-boot surface below the acknowledgement floor is not evidence"
    );
    assert_eq!(
        activation.receive_snapshot(&target, 7, &test_snapshot("remote-boot", 4)),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&target, 7, surface("remote-boot", 4, "pane")),
        SurfaceActivationProgress::Ready
    );
}

#[test]
fn stale_generation_and_boot_are_not_activation_evidence() {
    let mut activation = machine();
    assert_eq!(
        activation.receive_surface(&endpoint(), 6, surface("remote-boot", 1, "pane")),
        SurfaceActivationProgress::Stale
    );
    assert_eq!(
        activation.receive_surface(&endpoint(), 7, surface("old-boot", 1, "pane")),
        SurfaceActivationProgress::Stale
    );
}

#[test]
fn stale_response_boot_is_not_consumed() {
    let mut activation = machine();
    let (_shell, mut endpoints, _local_sent, _remote_sent) = shell_and_registry();
    assert_eq!(
        activation.receive_response_for_boot(
            &endpoint(),
            7,
            "old-boot",
            "client-shell-surface:3:on",
            &surface_success("client-shell-surface:3:on", true, 2),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Stale
    );
}

#[test]
fn same_target_retarget_is_latest_wins() {
    let (shell, mut endpoints, _local_sent, remote_sent) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        Some(crate::client::shell::ClientEndpointFocusTarget::Workspace(
            "old".into(),
        )),
        resize(),
        12,
        Instant::now(),
    )
    .unwrap();
    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:12:off",
        &surface_success("client-shell-surface:12:off", false, 1),
        &mut endpoints,
    );
    let old_focus = remote_sent
        .lock()
        .unwrap()
        .iter()
        .find_map(|message| match message {
            crate::protocol::ClientMessage::ClientShellEndpointRequest { request, .. }
                if surface_set_active(message).is_none() =>
            {
                Some(
                    serde_json::from_str::<crate::api::schema::Request>(request)
                        .unwrap()
                        .id,
                )
            }
            _ => None,
        })
        .unwrap();
    let sent_before_retarget = remote_sent.lock().unwrap().len();
    activation
        .retarget(
            Some(crate::client::shell::ClientEndpointFocusTarget::Workspace(
                "new".into(),
            )),
            &mut endpoints,
        )
        .unwrap();
    assert_eq!(remote_sent.lock().unwrap().len(), sent_before_retarget);
    assert!(activation.accepts_response(&target, 7, "remote-boot", &old_focus));
    assert_eq!(
        activation.receive_response(
            &target,
            7,
            &old_focus,
            &workspace_focus_success(&old_focus, "old"),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Pending
    );
    let latest_focus = remote_sent
        .lock()
        .unwrap()
        .last()
        .and_then(|message| match message {
            crate::protocol::ClientMessage::ClientShellEndpointRequest { request, .. } => Some(
                serde_json::from_str::<crate::api::schema::Request>(request)
                    .unwrap()
                    .id,
            ),
            _ => None,
        })
        .unwrap();
    assert_ne!(latest_focus, old_focus);
    assert!(activation.accepts_response(&target, 7, "remote-boot", &latest_focus));
}

#[test]
fn latest_host_focus_is_replayed_to_the_eventual_target() {
    let (shell, mut endpoints, _local_sent, remote_sent) = shell_and_registry();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        25,
        Instant::now(),
    )
    .unwrap();
    activation.update_host_focus(false, &mut endpoints).unwrap();
    assert!(remote_sent.lock().unwrap().is_empty());

    let _ = activation.receive_response(
        &test_source(),
        1,
        "client-shell-surface:25:off",
        &surface_success("client-shell-surface:25:off", false, 1),
        &mut endpoints,
    );
    assert_eq!(
        remote_sent.lock().unwrap().get(2),
        Some(&crate::protocol::ClientMessage::ClientShellFocus { focused: false })
    );

    activation.update_host_focus(true, &mut endpoints).unwrap();
    assert_eq!(
        remote_sent.lock().unwrap().last(),
        Some(&crate::protocol::ClientMessage::ClientShellFocus { focused: true })
    );
}

use super::*;
