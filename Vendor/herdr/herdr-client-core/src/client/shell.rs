use super::endpoint::{ClientEndpointId, ClientEndpointStatus, EndpointRegistry, SavedSshEndpoint};
use crate::protocol::{ClientShellSnapshot, PaneSurfaceFrame};
use std::collections::HashMap;
mod input;
pub use input::*;
#[path = "surface_patch.rs"]
mod surface_patch;
pub use surface_patch::ClientPaneSurfacePatchOutcome;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientEndpointFocusTarget {
    Workspace(String),
    Tab(String),
    Pane(String),
}

#[derive(Debug)]
pub struct ClientShellEndpointError {
    pub code: Option<String>,
    pub message: String,
}

#[derive(Clone)]
struct EndpointProjection {
    status: ClientEndpointStatus,
    generation: Option<u64>,
    snapshot: Option<Box<ClientShellSnapshot>>,
}

pub struct ClientShellState {
    endpoints: HashMap<ClientEndpointId, EndpointProjection>,
    active: ClientEndpointId,
    pub(crate) surface: Option<PaneSurfaceFrame>,
    focused: bool,
}

impl Default for ClientShellState {
    fn default() -> Self {
        Self::new()
    }
}

impl ClientShellState {
    pub fn new() -> Self {
        Self {
            endpoints: HashMap::new(),
            active: ClientEndpointId::Home,
            surface: None,
            focused: true,
        }
    }

    pub fn set_endpoint_catalog(&mut self, profiles: &[SavedSshEndpoint]) {
        self.endpoints.retain(|id, _| {
            profiles
                .iter()
                .any(|p| *id == ClientEndpointId::Ssh(p.id.clone()) && p.enabled)
        });
        for profile in profiles {
            let id = ClientEndpointId::Ssh(profile.id.clone());
            let status = if profile.enabled {
                ClientEndpointStatus::Connecting
            } else {
                ClientEndpointStatus::Disabled
            };
            self.endpoints.entry(id).or_insert(EndpointProjection {
                status,
                generation: None,
                snapshot: None,
            });
        }
        if !self.endpoints.contains_key(&self.active) {
            self.select_unavailable_home();
        }
    }

    pub fn receive_snapshot(
        &mut self,
        registry: &EndpointRegistry,
        incoming: SnapshotUpdate,
    ) -> bool {
        if !registry.accepts(&incoming.endpoint, incoming.generation) {
            return false;
        }
        self.set_endpoint_snapshot_for_generation(
            &incoming.endpoint,
            incoming.generation,
            incoming.snapshot,
        );
        true
    }

    pub(crate) fn set_endpoint_snapshot_for_generation(
        &mut self,
        endpoint: &ClientEndpointId,
        generation: u64,
        snapshot: Box<ClientShellSnapshot>,
    ) {
        let entry = self
            .endpoints
            .entry(endpoint.clone())
            .or_insert(EndpointProjection {
                status: ClientEndpointStatus::Online,
                generation: None,
                snapshot: None,
            });
        if entry.generation == Some(generation)
            && entry.snapshot.as_ref().is_some_and(|previous| {
                previous.boot_id == snapshot.boot_id && previous.revision > snapshot.revision
            })
        {
            return;
        }
        entry.generation = Some(generation);
        entry.snapshot = Some(snapshot);
    }

    pub fn endpoint_snapshot(&self, endpoint: &ClientEndpointId) -> Option<&ClientShellSnapshot> {
        self.endpoints.get(endpoint)?.snapshot.as_deref()
    }

    pub(crate) fn endpoint_snapshot_identity(
        &self,
        endpoint: &ClientEndpointId,
        generation: u64,
    ) -> Option<(&str, u64)> {
        let projection = self.endpoints.get(endpoint)?;
        if projection.generation != Some(generation) {
            return None;
        }
        projection
            .snapshot
            .as_deref()
            .map(|snapshot| (snapshot.boot_id.as_str(), snapshot.revision))
    }

    pub(crate) fn endpoint_snapshot_matches(
        &self,
        endpoint: &ClientEndpointId,
        generation: u64,
        boot: &str,
        revision: u64,
    ) -> bool {
        self.endpoint_snapshot_identity(endpoint, generation) == Some((boot, revision))
    }

    pub(crate) fn endpoint_boot_id(&self, endpoint: &ClientEndpointId) -> Option<&str> {
        self.endpoint_snapshot(endpoint)
            .map(|snapshot| snapshot.boot_id.as_str())
    }

    pub fn set_endpoint_status(
        &mut self,
        endpoint: &ClientEndpointId,
        status: ClientEndpointStatus,
    ) {
        if let Some(projection) = self.endpoints.get_mut(endpoint) {
            projection.status = status;
        }
    }

    pub fn endpoint_status(&self, endpoint: &ClientEndpointId) -> Option<ClientEndpointStatus> {
        self.endpoints
            .get(endpoint)
            .map(|projection| projection.status)
    }

    pub fn complete_activation(
        &mut self,
        registry: &mut EndpointRegistry,
        pending: &mut super::endpoint::PendingEndpointActivation,
    ) -> Result<super::endpoint::ActivationCompletion, String> {
        use super::endpoint::ActivationCompletion;
        let completion = pending.complete(self, registry)?;
        match completion {
            ActivationCompletion::Activated | ActivationCompletion::RestoredSource { .. } => {
                registry.unfreeze_input()
            }
            ActivationCompletion::AwaitingPresentationSync { .. }
            | ActivationCompletion::AwaitingPresentationEffects => registry.freeze_input(),
        }
        Ok(completion)
    }

    pub(crate) fn endpoint_projection_available(&self, endpoint: &ClientEndpointId) -> bool {
        self.endpoints
            .get(endpoint)
            .is_some_and(|p| p.status == ClientEndpointStatus::Online && p.snapshot.is_some())
    }

    pub(crate) fn activate_endpoint_projection(&mut self, endpoint: &ClientEndpointId) -> bool {
        if !self.endpoint_projection_available(endpoint) {
            return false;
        }
        if self.active != *endpoint {
            self.surface = None;
        }
        self.active = endpoint.clone();
        true
    }

    pub(crate) fn endpoint_is_active(&self, endpoint: &ClientEndpointId) -> bool {
        self.active == *endpoint
    }
    pub(crate) fn set_pane_surface(&mut self, surface: PaneSurfaceFrame) {
        self.surface = Some(surface);
    }
    pub fn surface(&self) -> Option<&PaneSurfaceFrame> {
        self.surface.as_ref()
    }
    pub fn receive_surface(
        &mut self,
        registry: &EndpointRegistry,
        incoming: SurfaceUpdate,
    ) -> Result<(), String> {
        if !registry.accepts(&incoming.endpoint, incoming.generation)
            || self.active != incoming.endpoint
            || !self.endpoint_snapshot_matches(
                &incoming.endpoint,
                incoming.generation,
                &incoming.surface.boot_id,
                incoming.surface.projection_revision,
            )
        {
            return Err("surface does not belong to the active endpoint lease".into());
        }
        crate::surface::validate_surface(&incoming.surface)?;
        if self.surface.as_ref().is_some_and(|current| {
            current.boot_id == incoming.surface.boot_id
                && current.surface_revision > incoming.surface.surface_revision
        }) {
            return Err("surface revision regressed".into());
        }
        self.set_pane_surface(incoming.surface);
        Ok(())
    }
    pub fn active_endpoint(&self) -> &ClientEndpointId {
        &self.active
    }
    pub const fn host_focus_baseline(&self) -> bool {
        self.focused
    }
    pub fn set_host_focus(&mut self, focused: bool) {
        self.focused = focused;
    }
    pub fn select_unavailable_home(&mut self) {
        self.active = ClientEndpointId::Home;
        self.surface = None;
    }
}

pub struct SnapshotUpdate {
    pub endpoint: ClientEndpointId,
    pub generation: u64,
    pub snapshot: Box<ClientShellSnapshot>,
}

pub struct SurfaceUpdate {
    pub endpoint: ClientEndpointId,
    pub generation: u64,
    pub surface: PaneSurfaceFrame,
}
