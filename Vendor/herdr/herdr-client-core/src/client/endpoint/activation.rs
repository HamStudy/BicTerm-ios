// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (1:14 1150:1152), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
use std::time::{Duration, Instant};

use super::{ClientEndpointId, ClientEndpointStatus, EndpointRegistry, EndpointSendOutcome};

mod model;
mod protocol;
pub use model::{
    ActivationBeginError, ActivationCompletion, ActivationRollback, EndpointActivationIntent,
    PendingEndpointActivation, SurfaceActivationProgress,
};
use model::{ActivationEvidence, ActivationPhase, EndpointLease};
use protocol::*;

const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
#[path = "activation_tests.rs"]
mod tests;

mod begin;

mod correlation;

mod response;

mod evidence;

mod rollback;

mod completion;

mod commands;
