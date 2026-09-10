// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation_tests.rs (255:450), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
#[test]
fn source_off_request_is_distinct_and_precedes_target_on_phase() {
    let activation = PendingEndpointActivation {
        source: lease(test_source(), 1, "local-boot"),
        source_available: true,
        target: lease(endpoint(), 7, "remote-boot"),
        focus: None,
        host_focused: true,
        resize: resize(),
        phase: ActivationPhase::ReleasingSource {
            request_id: "client-shell-surface:9:off".into(),
        },
        deadline: Instant::now() + ACTIVATION_TIMEOUT,
        epoch: 9,
        next_focus_serial: 0,
        rollback_error: None,
        successor: None,
    };
    assert!(activation.accepts_response(
        &test_source(),
        1,
        "local-boot",
        "client-shell-surface:9:off"
    ));
    assert!(!activation.accepts_response(
        &endpoint(),
        7,
        "remote-boot",
        "client-shell-surface:9:on"
    ));
}

#[test]
fn active_source_requires_metadata_from_its_current_connection_generation() {
    let (mut shell, mut endpoints, local_sent, remote_sent) = shell_and_registry();
    shell.set_endpoint_snapshot_for_generation(
        &test_source(),
        99,
        Box::new(test_snapshot("stale-local-boot", 1)),
    );

    let result = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        26,
        Instant::now(),
    );

    assert!(
        matches!(result, Err(ActivationBeginError::Preflight(message)) if message.contains("this connection"))
    );
    assert!(local_sent.lock().unwrap().is_empty());
    assert!(remote_sent.lock().unwrap().is_empty());
    assert!(endpoints.active_surface_available());
}

#[test]
fn observed_begin_write_failure_returns_recoverable_partial_activation() {
    let (shell, mut endpoints, local_sent, remote_sent) =
        shell_and_registry_with_source_failure(true);
    let result = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        endpoint(),
        None,
        resize(),
        10,
        Instant::now(),
    );

    let ActivationBeginError::Partial {
        mut activation,
        error,
    } = (match result {
        Err(error) => error,
        Ok(_) => panic!("an observed source write must return partial lifecycle state"),
    })
    else {
        panic!("an observed source write must return partial lifecycle state");
    };
    assert!(error.contains("focus revoke"));
    assert_eq!(
        local_sent.lock().unwrap().first(),
        Some(&crate::protocol::ClientMessage::ClientShellFocus { focused: false })
    );
    assert!(remote_sent.lock().unwrap().is_empty());
    assert!(matches!(
        activation.rollback(&mut endpoints, error, false),
        ActivationRollback::Unavailable(_)
    ));
}

#[test]
fn source_release_is_sent_and_acknowledged_before_target_activation() {
    let (shell, mut endpoints, local_sent, remote_sent) = shell_and_registry();
    let target = endpoint();
    let mut activation = PendingEndpointActivation::begin(
        &shell,
        &mut endpoints,
        target.clone(),
        None,
        resize(),
        11,
        Instant::now(),
    )
    .unwrap();
    let local = local_sent.lock().unwrap();
    assert_eq!(
        local.first(),
        Some(&crate::protocol::ClientMessage::ClientShellFocus { focused: false }),
        "source focus is revoked before source-off"
    );
    assert_eq!(
        local
            .as_slice()
            .iter()
            .filter_map(surface_set_active)
            .collect::<Vec<_>>(),
        vec![false],
        "the source is released first"
    );
    drop(local);
    assert!(remote_sent.lock().unwrap().is_empty());
    assert!(
        !endpoints.active_surface_available(),
        "pane input is blocked while frozen"
    );

    assert_eq!(
        activation.receive_response(
            &test_source(),
            1,
            "client-shell-surface:11:off",
            &surface_success("client-shell-surface:11:off", false, 1),
            &mut endpoints,
        ),
        SurfaceActivationProgress::Pending
    );
    let remote = remote_sent.lock().unwrap();
    assert!(matches!(
        remote[0],
        crate::protocol::ClientMessage::ClientShellResize { .. }
    ));
    assert_eq!(
        remote.get(2),
        Some(&crate::protocol::ClientMessage::ClientShellFocus { focused: true })
    );
    assert_eq!(remote.get(1).and_then(surface_set_active), Some(true));
}

#[test]
fn activation_requires_an_exact_snapshot_surface_revision_pair() {
    let mut activation = machine();
    let target = endpoint();
    let snapshot = crate::protocol::ClientShellSnapshot {
        boot_id: "remote-boot".into(),
        revision: 2,
        config_diagnostic: None,
        product_announcement: None,
        update_available: None,
        update_install_command: String::new(),
        server_keybindings_toml: None,
        latest_release_notes_available: false,
        integration_updates_available: false,
        worktree_directory: String::new(),
        release_notes: None,
        focused_workspace_id: None,
        focused_tab_id: None,
        focused_pane_id: None,
        tab_bar_right: Vec::new(),
        tab_bar_right_separator: String::new(),
        agent_view_label: None,
        agent_order: Vec::new(),
        workspaces: Vec::new(),
        tabs: Vec::new(),
        panes: Vec::new(),
        agents: Vec::new(),
        commands: Vec::new(),
    };
    assert_eq!(
        activation.receive_snapshot(&target, 7, &snapshot),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&target, 7, surface("remote-boot", 1, "pane")),
        SurfaceActivationProgress::Pending
    );
    assert_eq!(
        activation.receive_surface(&target, 7, surface("remote-boot", 2, "pane")),
        SurfaceActivationProgress::Ready
    );
}

use super::*;
