// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/registry.rs (364:397), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
use std::sync::{Arc, Mutex};

use super::*;

struct FakeTransport {
    sent: Arc<Mutex<Vec<ClientMessage>>>,
    error: Option<io::ErrorKind>,
}

impl EndpointTransport for FakeTransport {
    fn send(&mut self, message: &ClientMessage) -> io::Result<()> {
        if let Some(kind) = self.error {
            return Err(io::Error::new(kind, "fake transport failure"));
        }
        self.sent.lock().unwrap().push(message.clone());
        Ok(())
    }
}

fn negotiation() -> EndpointNegotiation {
    EndpointNegotiation::new(
        vec!["client_shell.surface.set".into()],
        vec![
            crate::protocol::endpoint::SURFACE_INTEREST_CAPABILITY.into(),
            crate::protocol::endpoint::PRESENTATION_EFFECTS_FENCE_CAPABILITY.into(),
            crate::protocol::endpoint::HEALTH_CHECK_CAPABILITY.into(),
        ],
    )
}

fn profile() -> crate::client::endpoint::ProfileId {
    crate::client::endpoint::ProfileId::parse("0123456789abcdef0123456789abcdef").unwrap()
}

use super::super::test_source;

#[path = "registry_cases/isolation.rs"]
mod isolation;

#[path = "registry_cases/health.rs"]
mod health;
