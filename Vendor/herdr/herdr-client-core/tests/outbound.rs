use herdr_client_core::{outbound::*, protocol::*, EndpointTransport};

#[test]
fn queue_preserves_exact_encoded_frames() {
    // Given
    let mut queue = OutboundQueue::new(QueueLimits {
        messages: 2,
        bytes: 1024,
    });
    let message = ClientMessage::ClientShellFocus { focused: true };
    queue.send(&message).unwrap();
    // When
    let frame = queue.drain_frame().unwrap().unwrap();
    // Then
    let decoded: ClientMessage = read_message(&mut frame.as_slice(), MAX_FRAME_SIZE).unwrap();
    assert_eq!(decoded, message);
    assert!(queue.drain_frame().unwrap().is_none());
}

#[test]
fn full_queue_failure_does_not_drop_an_accepted_frame() {
    // Given
    let mut queue = OutboundQueue::new(QueueLimits {
        messages: 1,
        bytes: 1024,
    });
    queue.send(&ClientMessage::Detach).unwrap();
    // When
    let error = queue
        .send(&ClientMessage::Input { data: vec![1] })
        .unwrap_err();
    // Then
    assert_eq!(error.kind(), std::io::ErrorKind::ConnectionAborted);
    let frame = queue.drain_frame().unwrap().unwrap();
    assert_eq!(
        read_message::<_, ClientMessage>(&mut frame.as_slice(), MAX_FRAME_SIZE).unwrap(),
        ClientMessage::Detach
    );
}

#[test]
fn disconnect_revokes_buffered_input_instead_of_replaying_it() {
    // Given
    let mut queue = OutboundQueue::new(QueueLimits {
        messages: 2,
        bytes: 1024,
    });
    queue
        .send(&ClientMessage::Input {
            data: b"dangerous-command".to_vec(),
        })
        .unwrap();
    let reader = queue.clone();
    // When
    queue.disconnect();
    // Then
    assert_eq!(
        reader.drain_frame().unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
}
