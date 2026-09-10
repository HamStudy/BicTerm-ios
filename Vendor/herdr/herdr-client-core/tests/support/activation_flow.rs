use super::*;

#[test]
fn byte_transport_activation_keeps_input_frozen_through_the_presentation_fence() {
    // Given: a connected remote endpoint with metadata, no selected surface.
    let mut world = World::begin();
    let messages = world.drain();
    assert!(matches!(
        messages.as_slice(),
        [
            ClientMessage::ClientShellResize { .. },
            ClientMessage::ClientShellEndpointRequest { .. },
            ClientMessage::ClientShellFocus { focused: true }
        ]
    ));
    // When: activation, replay and the presentation-ready fence arrive in order.
    world.acknowledge("client-shell-surface:1:on", 1);
    assert!(matches!(
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap(),
        ActivationCompletion::AwaitingPresentationSync { .. }
    ));
    let input = world.input();
    assert_eq!(
        world.shell.send_pane_input(&mut world.registry, input),
        Err(InputError::Frozen)
    );
    world.acknowledge("client-shell-surface:1:presentation-sync", 2);
    assert_eq!(
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap(),
        ActivationCompletion::AwaitingPresentationEffects
    );
    assert_eq!(
        world
            .activation
            .receive_presentation_effects_ready(&world.endpoint, 1, "stale-token"),
        SurfaceActivationProgress::Stale
    );
    assert!(!world.registry.active_surface_available());
    world
        .activation
        .receive_presentation_effects_ready(&world.endpoint, 1, "1:1:boot");
    assert_eq!(
        world
            .shell
            .complete_activation(&mut world.registry, &mut world.activation)
            .unwrap(),
        ActivationCompletion::Activated
    );
    world.drain();
    let input = world.input();
    world
        .shell
        .send_pane_input(&mut world.registry, input)
        .unwrap();
    // Then: one semantic paste is encoded for the selected pane, with no early input.
    assert_eq!(
        world.drain(),
        vec![ClientMessage::ClientShellPaneInput {
            pane_id: "p1".into(),
            events: vec![ClientPaneInputEvent::Paste("hello".into())]
        }]
    );
}

#[test]
fn advanced_metadata_without_a_coherent_surface_rejects_input() {
    // Given
    let mut world = World::ready();
    world.shell.receive_snapshot(
        &world.registry,
        SnapshotUpdate {
            endpoint: world.endpoint.clone(),
            generation: 1,
            snapshot: Box::new(snapshot(3)),
        },
    );
    let input = world.input();
    // When
    let result = world.shell.send_pane_input(&mut world.registry, input);
    // Then
    assert_eq!(result, Err(InputError::StaleTarget));
    assert!(world.drain().is_empty());
}
