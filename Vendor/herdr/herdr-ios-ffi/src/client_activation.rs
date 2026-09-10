//! Surface activation driving (doc §7): begin, evidence feed completion,
//! and resize routing for the in-flight transaction. Split from
//! `client.rs` so each module stays under the reviewed size ceiling.
use crate::client::HerdrClient;
use crate::{FfiError, HERDR_CODE_DISCONNECTED};
use herdr_client_core::client::endpoint::{PendingEndpointActivation, SurfaceActivationProgress};
use herdr_client_core::EndpointTransport;
use herdr_protocol::{ClientMessage, ClientSurfaceSize};
use std::time::Instant;

impl HerdrClient {
    fn resize_message(&self, cols: u16, rows: u16) -> ClientMessage {
        ClientMessage::ClientShellResize {
            cell_width_px: self.cell_width_px,
            cell_height_px: self.cell_height_px,
            surface_size: ClientSurfaceSize { cols, rows },
            pixel_mouse: self.pixel_mouse,
        }
    }

    /// Starts the surface activation transaction with a unique per-instance
    /// serial and the current geometry. Fails closed when the endpoint does
    /// not (yet) support surface interest; the first accepted snapshot or
    /// welcome retries while no transaction is in flight. Once the endpoint
    /// projection is active, later snapshots do not restart a transaction.
    pub(crate) fn begin_activation_if_idle(&mut self) {
        if self.pending.is_some() || self.shell.active_endpoint() == &self.endpoint {
            return;
        }
        let resize = self.resize_message(self.cols, self.rows);
        self.activation_serial += 1;
        match PendingEndpointActivation::begin(
            &self.shell,
            &mut self.registry,
            self.endpoint.clone(),
            None,
            resize,
            self.activation_serial,
            Instant::now(),
        ) {
            Ok(pending) => self.pending = Some(pending),
            Err(_) => {}
        }
    }

    /// Commits the transaction when its evidence reaches `Ready`; a failed
    /// completion restores the pending transaction instead of failing the
    /// client, so later evidence can still settle it.
    pub(crate) fn try_complete_activation(&mut self, progress: SurfaceActivationProgress) {
        if !matches!(progress, SurfaceActivationProgress::Ready) {
            return;
        }
        if let Some(mut pending) = self.pending.take() {
            if self
                .shell
                .complete_activation(&mut self.registry, &mut pending)
                .is_err()
            {
                self.pending = Some(pending);
            }
        }
    }

    /// Updates the logical geometry and routes the resize through the
    /// in-flight activation when one exists so pending surface evidence is
    /// invalidated coherently; otherwise the frame is queued directly.
    pub(crate) fn resize(&mut self, cols: u32, rows: u32) -> Result<(), FfiError> {
        let cols = cols as u16;
        let rows = rows as u16;
        self.cols = cols;
        self.rows = rows;
        let message = self.resize_message(cols, rows);
        if let Some(pending) = self.pending.as_mut() {
            pending
                .update_resize(message, &mut self.registry)
                .map_err(|error| FfiError::new(HERDR_CODE_DISCONNECTED, error))?;
        } else {
            self.queue
                .send(&message)
                .map_err(|error| FfiError::new(HERDR_CODE_DISCONNECTED, error.to_string()))?;
        }
        Ok(())
    }
}
