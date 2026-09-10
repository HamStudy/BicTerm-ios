// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (147:240), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl EndpointRegistry {
    pub fn insert(
        &mut self,
        endpoint_id: ClientEndpointId,
        transport: impl EndpointTransport + 'static,
        generation: u64,
        negotiation: EndpointNegotiation,
        surface_active: bool,
    ) -> bool {
        if endpoint_id.is_home() {
            return false;
        }
        let health = (!endpoint_id.is_home() && negotiation.supports_health_check())
            .then(|| EndpointHealth::new(Instant::now()));
        if let Some(mut previous) = self.connections.insert(
            endpoint_id,
            EndpointConnection {
                transport: Box::new(transport),
                generation,
                surface_active,
                negotiation,
                health,
            },
        ) {
            previous.transport.disconnect();
        }
        true
    }

    pub fn accepts(&self, endpoint_id: &ClientEndpointId, generation: u64) -> bool {
        self.connections
            .get(endpoint_id)
            .is_some_and(|connection| connection.generation == generation)
    }

    pub fn received(&mut self, endpoint_id: &ClientEndpointId, generation: u64, now: Instant) {
        if let Some(health) = self
            .connections
            .get_mut(endpoint_id)
            .filter(|connection| connection.generation == generation)
            .and_then(|connection| connection.health.as_mut())
        {
            health.received(now);
        }
    }

    pub fn mark_ready(&mut self, endpoint_id: &ClientEndpointId, generation: u64) {
        if let Some(health) = self
            .connections
            .get_mut(endpoint_id)
            .filter(|connection| connection.generation == generation)
            .and_then(|connection| connection.health.as_mut())
        {
            health.ready();
        }
    }

    pub fn tick_health(&mut self, now: Instant) {
        let actions = self
            .connections
            .iter()
            .filter_map(|(endpoint_id, connection)| {
                connection
                    .health
                    .as_ref()
                    .map(|health| (endpoint_id.clone(), health.action(now)))
            })
            .filter(|(_, action)| *action != HealthAction::None)
            .collect::<Vec<_>>();
        for (endpoint_id, action) in actions {
            match action {
                HealthAction::None => {}
                HealthAction::Ping => {
                    let ping = ClientMessage::EndpointControl {
                        kind: crate::protocol::endpoint::HEALTH_PING_KIND.into(),
                        data: String::new(),
                    };
                    if self.send_to(&endpoint_id, &ping) == EndpointSendOutcome::Sent {
                        if let Some(health) = self
                            .connections
                            .get_mut(&endpoint_id)
                            .and_then(|connection| connection.health.as_mut())
                        {
                            health.ping_sent(now);
                        }
                    }
                }
                HealthAction::Expired => self.record_failure(
                    endpoint_id,
                    io::Error::new(io::ErrorKind::TimedOut, "endpoint health check timed out"),
                ),
            }
        }
    }
}
use super::*;
