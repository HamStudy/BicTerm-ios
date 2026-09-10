use herdr_protocol::*;
#[path = "support/client_samples.rs"]
mod client_samples;
#[path = "support/server_samples.rs"]
mod server_samples;

#[test]
fn every_client_variant_encodes_to_its_frozen_frame_and_decodes_losslessly() {
    // Given
    let messages = client_samples::samples().unwrap();
    assert_eq!(messages.len(), 21);
    for (tag, message) in messages.iter().enumerate() {
        let fixture = std::fs::read(format!(
            "{}/tests/fixtures/golden/client-{tag:02}.bin",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        // When
        let mut encoded = Vec::new();
        write_message(&mut encoded, message).unwrap();
        let decoded: ClientMessage = read_message(&mut fixture.as_slice(), MAX_FRAME_SIZE).unwrap();
        // Then
        assert_eq!(encoded, fixture, "client tag {tag}");
        assert_eq!(usize::from(encoded[4]), tag);
        assert_eq!(&decoded, message);
    }
}

#[test]
fn every_server_variant_encodes_to_its_frozen_frame_and_decodes_losslessly() {
    // Given
    let messages = server_samples::samples().unwrap();
    assert_eq!(messages.len(), 22);
    for (index, message) in messages.iter().enumerate() {
        let fixture = std::fs::read(format!(
            "{}/tests/fixtures/golden/server-{index:02}.bin",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        // When
        let mut encoded = Vec::new();
        write_message(&mut encoded, message).unwrap();
        let decoded: ServerMessage = read_message(&mut fixture.as_slice(), MAX_FRAME_SIZE).unwrap();
        // Then
        assert_eq!(encoded, fixture, "server sample {index}");
        assert_eq!(usize::from(encoded[4]), index.min(20));
        assert_eq!(&decoded, message);
    }
}

#[test]
fn trailing_bytes_inside_a_frame_are_rejected() {
    // Given
    let mut bytes = Vec::new();
    write_message(&mut bytes, &ClientMessage::Detach).unwrap();
    bytes[0] += 1;
    bytes.push(0);
    // When
    let result = read_message::<_, ClientMessage>(&mut bytes.as_slice(), MAX_FRAME_SIZE);
    // Then
    assert!(matches!(result, Err(FramingError::Bincode(_))));
}
