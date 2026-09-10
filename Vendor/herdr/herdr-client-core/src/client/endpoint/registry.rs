// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (1:146 241:266 347:360), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
use std::collections::{HashMap, HashSet};
use std::io;
use std::time::Instant;

use super::health::{EndpointHealth, HealthAction};
use super::ClientEndpointId;
use crate::protocol::ClientMessage;

pub trait EndpointTransport: Send {
    fn send(&mut self, message: &ClientMessage) -> io::Result<()>;

    fn disconnect(&mut self) {}

    fn flush(&mut self, _deadline: Instant) -> io::Result<()> {
        Ok(())
    }

    fn take_error(&mut self) -> Option<io::Error> {
        None
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EndpointNegotiation {
    methods: HashSet<String>,
    capabilities: HashSet<String>,
}

impl EndpointNegotiation {
    pub fn new(methods: Vec<String>, capabilities: Vec<String>) -> Self {
        Self {
            methods: methods.into_iter().collect(),
            capabilities: capabilities.into_iter().collect(),
        }
    }

    pub fn methods(&self) -> Vec<String> {
        self.methods.iter().cloned().collect()
    }

    pub fn supports_method(&self, method: &str) -> bool {
        self.methods.contains(method)
    }

    pub fn supports_capability(&self, capability: &str) -> bool {
        self.capabilities.contains(capability)
    }

    pub fn supports_surface_interest(&self) -> bool {
        self.supports_capability(crate::protocol::endpoint::SURFACE_INTEREST_CAPABILITY)
            && self.supports_capability(
                crate::protocol::endpoint::PRESENTATION_EFFECTS_FENCE_CAPABILITY,
            )
            && self.supports_method("client_shell.surface.set")
    }

    pub fn supports_health_check(&self) -> bool {
        self.supports_capability(crate::protocol::endpoint::HEALTH_CHECK_CAPABILITY)
    }
}

pub struct EndpointConnection {
    transport: Box<dyn EndpointTransport>,
    pub generation: u64,
    pub surface_active: bool,
    pub negotiation: EndpointNegotiation,
    health: Option<EndpointHealth>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EndpointTransportFailure {
    pub endpoint_id: ClientEndpointId,
    pub generation: u64,
    pub kind: io::ErrorKind,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndpointSendOutcome {
    Sent,
    NotSent,
}

pub struct EndpointRegistry {
    active: ClientEndpointId,
    input_enabled: bool,
    connections: HashMap<ClientEndpointId, EndpointConnection>,
    failures: Vec<EndpointTransportFailure>,
}

impl EndpointRegistry {
    pub fn empty() -> Self {
        Self {
            active: ClientEndpointId::Home,
            input_enabled: false,
            connections: HashMap::new(),
            failures: Vec::new(),
        }
    }

    #[cfg(test)]
    pub fn new(
        local: impl EndpointTransport + 'static,
        generation: u64,
        negotiation: EndpointNegotiation,
    ) -> Self {
        let mut registry = Self::empty();
        registry.input_enabled = true;
        registry.active = super::test_source();
        registry.insert(super::test_source(), local, generation, negotiation, true);
        registry
    }

    pub fn active_id(&self) -> &ClientEndpointId {
        &self.active
    }

    pub fn active_surface_available(&self) -> bool {
        self.input_enabled
            && self
                .connections
                .get(&self.active)
                .is_some_and(|connection| connection.surface_active)
    }

    pub fn select_unavailable_home(&mut self) {
        self.active = ClientEndpointId::Home;
        self.freeze_input();
    }

    pub fn freeze_input(&mut self) {
        self.input_enabled = false;
    }

    pub fn unfreeze_input(&mut self) {
        self.input_enabled = true;
    }

    pub fn connection(&self, endpoint_id: &ClientEndpointId) -> Option<&EndpointConnection> {
        self.connections.get(endpoint_id)
    }

    pub fn set_active(&mut self, endpoint_id: &ClientEndpointId) -> bool {
        if !self
            .connections
            .get(endpoint_id)
            .is_some_and(|connection| connection.surface_active)
        {
            return false;
        }
        self.active = endpoint_id.clone();
        true
    }

    pub fn set_surface_active(&mut self, endpoint_id: &ClientEndpointId, active: bool) -> bool {
        let Some(connection) = self.connections.get_mut(endpoint_id) else {
            return false;
        };
        let changed = connection.surface_active != active;
        connection.surface_active = active;
        changed
    }
}

impl Drop for EndpointRegistry {
    fn drop(&mut self) {
        let deadline = Instant::now() + std::time::Duration::from_millis(250);
        for connection in self.connections.values_mut() {
            let _ = connection.transport.send(&ClientMessage::Detach);
        }
        for connection in self.connections.values_mut() {
            let _ = connection.transport.flush(deadline);
            connection.transport.disconnect();
        }
    }
}

#[path = "registry_connections.rs"]
mod connections;
#[path = "registry_transport.rs"]
mod transport;

#[cfg(test)]
#[path = "registry_tests.rs"]
mod tests;
