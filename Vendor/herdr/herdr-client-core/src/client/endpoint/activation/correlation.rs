// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (144:294), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    pub fn target(&self) -> &ClientEndpointId {
        &self.target.endpoint_id
    }

    pub(super) fn geometry(&self) -> crate::protocol::ClientSurfaceSize {
        resize_geometry(&self.resize).expect("activation resize was validated before construction")
    }

    pub fn presentation_sync_endpoint(&self) -> Option<&ClientEndpointId> {
        match self.phase {
            ActivationPhase::ActivatingTarget { .. } => Some(&self.target.endpoint_id),
            ActivationPhase::RestoringSource { .. } => Some(&self.source.endpoint_id),
            _ => None,
        }
    }

    /// The complete source command lane cannot safely cross source-off into a later presentation
    /// epoch. Other endpoint lanes are not part of this retirement.
    pub fn source_command_lane(&self) -> Option<&ClientEndpointId> {
        (self.source_available && self.source.endpoint_id != self.target.endpoint_id)
            .then_some(&self.source.endpoint_id)
    }

    pub fn can_retarget(&self, endpoint_id: &ClientEndpointId) -> bool {
        self.target.endpoint_id == *endpoint_id
            && self.successor.is_none()
            && matches!(
                self.phase,
                ActivationPhase::ReleasingSource { .. } | ActivationPhase::ActivatingTarget { .. }
            )
    }

    /// Replace an in-flight handoff with the latest endpoint-qualified intent. The current
    /// transaction is still reversed through target-off/source-on; the replacement is launched
    /// by the caller only after the source's coherent restoration commits.
    pub fn supersede(
        &mut self,
        endpoint_id: ClientEndpointId,
        target: Option<crate::client::shell::ClientEndpointFocusTarget>,
        endpoints: &mut EndpointRegistry,
    ) -> ActivationRollback {
        self.successor = Some(EndpointActivationIntent {
            endpoint_id,
            target,
        });
        // Source-on is already ordered and must finish before any replacement is allowed to
        // begin. Later rapid selections only replace the retained intent; they never turn a
        // safe restoration into an unavailable state.
        let source_restoration_in_flight = matches!(
            self.phase,
            ActivationPhase::RestoringSource { .. }
        ) || matches!(
            &self.phase,
            ActivationPhase::SynchronizingPresentation { completion, .. }
                if matches!(completion.as_ref(), ActivationCompletion::RestoredSource { .. })
        );
        if source_restoration_in_flight {
            return ActivationRollback::Pending;
        }
        self.rollback(
            endpoints,
            "endpoint handoff superseded by a newer selection".into(),
            false,
        )
    }

    pub fn accepts_endpoint(&self, endpoint_id: &ClientEndpointId, generation: u64) -> bool {
        (self.source_available
            && self.source.endpoint_id == *endpoint_id
            && self.source.generation == generation)
            || (self.target.endpoint_id == *endpoint_id && self.target.generation == generation)
    }

    pub fn involves_endpoint(&self, endpoint_id: &ClientEndpointId) -> bool {
        self.source.endpoint_id == *endpoint_id || self.target.endpoint_id == *endpoint_id
    }

    pub fn accepts_response(
        &self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        boot_id: &str,
        request_id: &str,
    ) -> bool {
        match &self.phase {
            ActivationPhase::ReleasingSource {
                request_id: expected,
            } => {
                endpoint_matches(&self.source, endpoint_id, generation, boot_id)
                    && expected == request_id
            }
            ActivationPhase::ActivatingTarget {
                request_id: expected,
                focus_request_id,
                ..
            } => {
                endpoint_matches(&self.target, endpoint_id, generation, boot_id)
                    && (expected == request_id || focus_request_id.as_deref() == Some(request_id))
            }
            ActivationPhase::ReleasingTargetForRollback {
                request_id: expected,
            } => {
                endpoint_matches(&self.target, endpoint_id, generation, boot_id)
                    && expected == request_id
            }
            ActivationPhase::RestoringSource {
                request_id: expected,
                ..
            } => {
                endpoint_matches(&self.source, endpoint_id, generation, boot_id)
                    && expected == request_id
            }
            ActivationPhase::SynchronizingPresentation {
                lease,
                request_id: expected,
                ..
            } => {
                endpoint_matches(lease, endpoint_id, generation, boot_id) && expected == request_id
            }
            ActivationPhase::AwaitingPresentationEffects { .. } => false,
        }
    }

    pub fn expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }

    #[cfg(test)]
    pub fn receive_response(
        &mut self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        request_id: &str,
        data: &[u8],
        endpoints: &mut EndpointRegistry,
    ) -> SurfaceActivationProgress {
        let boot_id = if self.source.endpoint_id == *endpoint_id {
            self.source.boot_id.clone()
        } else {
            self.target.boot_id.clone()
        };
        self.receive_response_for_boot(
            endpoint_id,
            generation,
            &boot_id,
            request_id,
            data,
            endpoints,
        )
    }
}
use super::*;
