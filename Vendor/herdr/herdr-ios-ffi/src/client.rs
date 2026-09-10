//! Safe state machine behind the C ABI: one endpoint client per handle.
//! Mirrors the caller contract in `Vendor/herdr/README.md`: the caller owns
//! connection I/O; this side owns parsing, validation, and state mutation.
use crate::errors::handshake_error;
use crate::frame::{read_frame, FrameRead};
use crate::{
    FfiError, HERDR_CODE_CLIENT_FAILED, HERDR_CODE_DISCONNECTED, HERDR_CODE_PANIC,
    HERDR_CODE_PROTOCOL_VIOLATION, HERDR_CODE_SURFACE_REJECTED, HERDR_PHASE_AWAITING_WELCOME,
    HERDR_PHASE_FAILED, HERDR_PHASE_ONLINE,
};
use herdr_client_core::client::shell::{SnapshotUpdate, SurfaceUpdate};
use herdr_client_core::handshake::PendingHandshake;
use herdr_client_core::outbound::OutboundQueue;
use herdr_client_core::{
    ClientEndpointId, ClientEndpointStatus, ClientShellState, EndpointRegistry,
};
use herdr_protocol::endpoint::{ENDPOINT_SNAPSHOT_KIND, ENDPOINT_WELCOME_KIND};
use herdr_protocol::{ClientShellSnapshot, ServerMessage};
use std::io::Cursor;
use std::time::Instant;

pub(crate) struct HerdrClient {
    pub(crate) endpoint: ClientEndpointId,
    pub(crate) generation: u64,
    pub(crate) inbound: Vec<u8>,
    pub(crate) phase: Phase,
    pub(crate) queue: OutboundQueue,
    pub(crate) registry: EndpointRegistry,
    pub(crate) shell: ClientShellState,
    pub(crate) max_frame_size: usize,
    pub(crate) snapshot: Option<ClientShellSnapshot>,
    pub(crate) last_detail: std::ffi::CString,
}

pub(crate) enum Phase {
    AwaitingWelcome(Box<PendingHandshake>),
    Online,
    Failed,
}

impl HerdrClient {
    /// Appends transport bytes and decodes every complete server frame.
    /// Partial frames stay buffered; decode failures fail the client.
    pub(crate) fn receive(&mut self, bytes: &[u8]) -> Result<(), FfiError> {
        self.inbound.extend_from_slice(bytes);
        loop {
            if self.inbound.is_empty() {
                return Ok(());
            }
            let mut cursor = Cursor::new(&self.inbound[..]);
            match read_frame::<_, ServerMessage>(&mut cursor, self.max_frame_size) {
                Ok(message) => {
                    let consumed = cursor.position() as usize;
                    self.inbound.drain(..consumed);
                    self.handle_message(message)?;
                }
                Err(FrameRead::Partial) => return Ok(()),
                Err(FrameRead::Invalid(error)) => {
                    self.inbound.clear();
                    self.phase = Phase::Failed;
                    return Err(FfiError::new(
                        HERDR_CODE_PROTOCOL_VIOLATION,
                        error.to_string(),
                    ));
                }
            }
        }
    }

    fn handle_message(&mut self, message: ServerMessage) -> Result<(), FfiError> {
        // Phase moves to Online for the duration of handling; fatal arms
        // overwrite it with Failed before returning their error.
        let phase = std::mem::replace(&mut self.phase, Phase::Online);
        match phase {
            Phase::AwaitingWelcome(handshake) => {
                let negotiation = handshake
                    .receive(message, Instant::now())
                    .map_err(|error| {
                        self.phase = Phase::Failed;
                        handshake_error(error)
                    })?;
                self.registry.insert(
                    self.endpoint.clone(),
                    self.queue.clone(),
                    self.generation,
                    negotiation,
                    true,
                );
                self.shell
                    .set_endpoint_status(&self.endpoint, ClientEndpointStatus::Online);
                Ok(())
            }
            Phase::Online => self.handle_online_message(message),
            Phase::Failed => {
                self.phase = Phase::Failed;
                Err(FfiError::new(
                    HERDR_CODE_CLIENT_FAILED,
                    "client already failed a protocol check; destroy and reconnect",
                ))
            }
        }
    }

    fn handle_online_message(&mut self, message: ServerMessage) -> Result<(), FfiError> {
        self.registry
            .received(&self.endpoint, self.generation, Instant::now());
        match message {
            ServerMessage::EndpointControl { kind, data } => {
                if kind == ENDPOINT_SNAPSHOT_KIND {
                    self.apply_snapshot_body(&data)
                } else if kind == ENDPOINT_WELCOME_KIND {
                    self.phase = Phase::Failed;
                    Err(FfiError::new(
                        HERDR_CODE_PROTOCOL_VIOLATION,
                        "endpoint welcome received after handshake completed",
                    ))
                } else {
                    // Unknown named controls are optional and ignored (doc §4).
                    Ok(())
                }
            }
            ServerMessage::ClientShellSnapshot(snapshot) => self.apply_snapshot(*snapshot),
            ServerMessage::PaneSurface(surface) => {
                let update = SurfaceUpdate {
                    endpoint: self.endpoint.clone(),
                    generation: self.generation,
                    surface,
                };
                self.shell
                    .receive_surface(&self.registry, update)
                    .map_err(|detail| FfiError::new(HERDR_CODE_SURFACE_REJECTED, detail))
            }
            _ => Ok(()),
        }
    }

    fn apply_snapshot_body(&mut self, data: &str) -> Result<(), FfiError> {
        match serde_json::from_str::<ClientShellSnapshot>(data) {
            Ok(snapshot) => self.apply_snapshot(snapshot),
            Err(error) => {
                self.phase = Phase::Failed;
                Err(FfiError::new(
                    HERDR_CODE_PROTOCOL_VIOLATION,
                    format!("snapshot codec payload is not valid JSON: {error}"),
                ))
            }
        }
    }

    fn apply_snapshot(&mut self, snapshot: ClientShellSnapshot) -> Result<(), FfiError> {
        let update = SnapshotUpdate {
            endpoint: self.endpoint.clone(),
            generation: self.generation,
            snapshot: Box::new(snapshot.clone()),
        };
        if self.shell.receive_snapshot(&self.registry, update) {
            let had_snapshot = self.snapshot.is_some();
            self.snapshot = Some(snapshot);
            if !had_snapshot {
                self.registry.mark_ready(&self.endpoint, self.generation);
            }
        }
        Ok(())
    }

    /// Pops one complete length-prefixed outbound frame for the caller's
    /// transport write; `None` means the queue is currently empty.
    pub(crate) fn drain_outbound(&mut self) -> Result<Option<Vec<u8>>, FfiError> {
        self.queue
            .drain_frame()
            .map_err(|error| FfiError::new(HERDR_CODE_DISCONNECTED, error.to_string()))
    }

    pub(crate) fn snapshot_json(&self) -> Result<Option<String>, FfiError> {
        Self::json_of(self.snapshot.as_ref())
    }

    pub(crate) fn surface_json(&self) -> Result<Option<String>, FfiError> {
        Self::json_of(self.shell.surface())
    }

    fn json_of<T: serde::ser::Serialize>(value: Option<&T>) -> Result<Option<String>, FfiError> {
        match value {
            Some(value) => serde_json::to_string(value)
                .map(Some)
                .map_err(|error| FfiError::new(HERDR_CODE_PANIC, error.to_string())),
            None => Ok(None),
        }
    }

    pub(crate) fn phase(&self) -> u32 {
        match self.phase {
            Phase::AwaitingWelcome { .. } => HERDR_PHASE_AWAITING_WELCOME,
            Phase::Online => HERDR_PHASE_ONLINE,
            Phase::Failed => HERDR_PHASE_FAILED,
        }
    }

    pub(crate) fn pending_inbound(&self) -> u64 {
        self.inbound.len() as u64
    }
}
