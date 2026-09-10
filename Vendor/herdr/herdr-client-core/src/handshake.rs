// Adapted from upstream client/handshake.rs: no socket, terminal, or process discovery.
use crate::protocol::endpoint::*;
use crate::protocol::{ClientMessage, ServerMessage};
use crate::EndpointNegotiation;
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum HandshakeError {
    TimedOut,
    ExpectedWelcome,
    InvalidWelcome,
    Incompatible,
    Rejected(String),
}

pub struct PendingHandshake {
    deadline: Instant,
}

impl PendingHandshake {
    pub fn begin(
        hello: &EndpointClientHello,
        now: Instant,
    ) -> Result<(Self, ClientMessage), HandshakeError> {
        if hello.generation != ENDPOINT_PROTOCOL_GENERATION
            || !hello.supports_required_codecs()
            || hello.direct_graphics
        {
            return Err(HandshakeError::Incompatible);
        }
        let data = serde_json::to_string(hello).map_err(|_| HandshakeError::InvalidWelcome)?;
        Ok((
            Self {
                deadline: now + Duration::from_secs(60),
            },
            ClientMessage::EndpointControl {
                kind: ENDPOINT_HELLO_KIND.into(),
                data,
            },
        ))
    }

    pub fn receive(
        self,
        message: ServerMessage,
        now: Instant,
    ) -> Result<EndpointNegotiation, HandshakeError> {
        if now >= self.deadline {
            return Err(HandshakeError::TimedOut);
        }
        let ServerMessage::EndpointControl { kind, data } = message else {
            return Err(HandshakeError::ExpectedWelcome);
        };
        if kind != ENDPOINT_WELCOME_KIND {
            return Err(HandshakeError::ExpectedWelcome);
        }
        let welcome: EndpointServerWelcome =
            serde_json::from_str(&data).map_err(|_| HandshakeError::InvalidWelcome)?;
        if let Some(error) = welcome.error {
            return Err(HandshakeError::Rejected(error.message));
        }
        if welcome.generation != ENDPOINT_PROTOCOL_GENERATION
            || welcome.snapshot_codec != SNAPSHOT_CODEC_V1
            || welcome.surface_codec != SURFACE_CODEC_V1
            || welcome.input_codec != INPUT_CODEC_V1
            || welcome.blob_codec != BLOB_CODEC_V1
        {
            return Err(HandshakeError::Incompatible);
        }
        let negotiation = EndpointNegotiation::new(welcome.methods, welcome.capabilities);
        if !negotiation.supports_surface_interest() || !negotiation.supports_health_check() {
            return Err(HandshakeError::Incompatible);
        }
        Ok(negotiation)
    }

    pub fn expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }
}
