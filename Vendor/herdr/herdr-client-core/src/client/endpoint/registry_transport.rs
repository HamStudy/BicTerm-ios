// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (267:346), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl EndpointRegistry {
    pub fn send(&mut self, message: &ClientMessage) -> EndpointSendOutcome {
        let endpoint_id = self.active.clone();
        self.send_to(&endpoint_id, message)
    }

    pub fn send_to(
        &mut self,
        endpoint_id: &ClientEndpointId,
        message: &ClientMessage,
    ) -> EndpointSendOutcome {
        let result = self
            .connections
            .get_mut(endpoint_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "endpoint is unavailable"))
            .and_then(|connection| connection.transport.send(message));
        match result {
            Ok(()) => EndpointSendOutcome::Sent,
            Err(error) => {
                self.record_failure(endpoint_id.clone(), error);
                EndpointSendOutcome::NotSent
            }
        }
    }

    pub fn disconnect(&mut self, endpoint_id: &ClientEndpointId) {
        self.failures
            .retain(|failure| &failure.endpoint_id != endpoint_id);
        if let Some(mut connection) = self.connections.remove(endpoint_id) {
            connection.transport.disconnect();
        }
    }

    pub fn fail(&mut self, endpoint_id: &ClientEndpointId, error: io::Error) {
        self.record_failure(endpoint_id.clone(), error);
    }

    pub fn take_failures(&mut self) -> Vec<EndpointTransportFailure> {
        let errors = self
            .connections
            .iter_mut()
            .filter_map(|(id, connection)| {
                connection
                    .transport
                    .take_error()
                    .map(|error| (id.clone(), error))
            })
            .collect::<Vec<_>>();
        for (endpoint_id, error) in errors {
            self.record_failure(endpoint_id, error);
        }
        std::mem::take(&mut self.failures)
    }

    pub(super) fn record_failure(&mut self, endpoint_id: ClientEndpointId, error: io::Error) {
        let Some(generation) = self
            .connections
            .get(&endpoint_id)
            .map(|connection| connection.generation)
        else {
            return;
        };
        let failure = EndpointTransportFailure {
            endpoint_id: endpoint_id.clone(),
            generation,
            kind: error.kind(),
            message: error.to_string(),
        };
        if let Some(mut connection) = self.connections.remove(&endpoint_id) {
            connection.transport.disconnect();
        }
        if let Some(existing) = self
            .failures
            .iter_mut()
            .find(|existing| existing.endpoint_id == endpoint_id)
        {
            *existing = failure;
        } else {
            self.failures.push(failure);
        }
    }
}
use super::*;
