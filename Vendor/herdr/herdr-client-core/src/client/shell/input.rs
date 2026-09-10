use super::*;
use crate::protocol::{ClientMessage, ClientPaneInputEvent};
use crate::EndpointSendOutcome;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QualifiedPane {
    pub endpoint: ClientEndpointId,
    pub generation: u64,
    pub boot_id: String,
    pub pane_id: String,
}

pub struct PaneInput {
    pub target: QualifiedPane,
    pub event: ClientPaneInputEvent,
}

#[derive(Debug, PartialEq, Eq)]
pub enum InputError {
    Frozen,
    StaleTarget,
    WriteFailed,
}

impl ClientShellState {
    pub fn send_pane_input(
        &self,
        registry: &mut EndpointRegistry,
        input: PaneInput,
    ) -> Result<(), InputError> {
        if !registry.active_surface_available() {
            return Err(InputError::Frozen);
        }
        let target = &input.target;
        if registry.active_id() != &target.endpoint
            || !registry.accepts(&target.endpoint, target.generation)
            || !self.endpoint_is_active(&target.endpoint)
            || self.endpoint_boot_id(&target.endpoint) != Some(target.boot_id.as_str())
            || !self.surface.as_ref().is_some_and(|surface| {
                surface.boot_id == target.boot_id
                    && self.endpoint_snapshot_matches(
                        &target.endpoint,
                        target.generation,
                        &target.boot_id,
                        surface.projection_revision,
                    )
                    && surface
                        .panes
                        .iter()
                        .any(|pane| pane.pane_id == target.pane_id)
            })
        {
            return Err(InputError::StaleTarget);
        }
        let message = ClientMessage::ClientShellPaneInput {
            pane_id: target.pane_id.clone(),
            events: vec![input.event],
        };
        match registry.send_to(&target.endpoint, &message) {
            EndpointSendOutcome::Sent => Ok(()),
            EndpointSendOutcome::NotSent => Err(InputError::WriteFailed),
        }
    }
}
