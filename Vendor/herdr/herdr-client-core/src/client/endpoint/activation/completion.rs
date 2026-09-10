// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (818:920), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    pub fn complete(
        &mut self,
        shell: &mut crate::client::shell::ClientShellState,
        endpoints: &mut EndpointRegistry,
    ) -> Result<ActivationCompletion, String> {
        if let ActivationPhase::SynchronizingPresentation {
            lease,
            acknowledged_revision,
            evidence,
            completion,
            ..
        } = &self.phase
        {
            let lease = lease.clone();
            let completion = (**completion).clone();
            let surface = coherent_completion_surface(
                shell,
                &lease,
                evidence,
                *acknowledged_revision,
                self.geometry(),
            )?;
            if endpoints.active_id() != &lease.endpoint_id
                || !shell.endpoint_projection_available(&lease.endpoint_id)
                || !shell.activate_endpoint_projection(&lease.endpoint_id)
            {
                return Err(
                    "endpoint became unavailable during presentation synchronization".into(),
                );
            }
            shell.set_pane_surface(surface);
            self.start_presentation_effects_fence(endpoints, lease, completion)?;
            return Ok(ActivationCompletion::AwaitingPresentationEffects);
        }
        if let ActivationPhase::AwaitingPresentationEffects {
            ready: true,
            completion,
            ..
        } = &self.phase
        {
            return Ok((**completion).clone());
        }

        let (lease, evidence, acknowledgement_revision, completion) = match &self.phase {
            ActivationPhase::ActivatingTarget {
                evidence,
                acknowledged_revision,
                ..
            } => {
                let completion = ActivationCompletion::Activated;
                (
                    self.target.clone(),
                    evidence,
                    *acknowledged_revision,
                    completion,
                )
            }
            ActivationPhase::RestoringSource {
                evidence,
                acknowledged_revision,
                ..
            } => {
                let completion = ActivationCompletion::RestoredSource {
                    error: self
                        .rollback_error
                        .clone()
                        .unwrap_or_else(|| "endpoint handoff was rolled back".into()),
                    successor: self.successor.clone(),
                };
                (
                    self.source.clone(),
                    evidence,
                    *acknowledged_revision,
                    completion,
                )
            }
            _ => return Err("endpoint activation completed in an invalid phase".into()),
        };
        let surface = coherent_completion_surface(
            shell,
            &lease,
            evidence,
            acknowledgement_revision,
            self.geometry(),
        )?;
        endpoints.set_surface_active(&lease.endpoint_id, true);
        shell.set_endpoint_status(&lease.endpoint_id, ClientEndpointStatus::Online);
        if !shell.endpoint_projection_available(&lease.endpoint_id)
            || !endpoints.set_active(&lease.endpoint_id)
        {
            return Err("endpoint became unavailable during activation".into());
        }
        let activated = shell.activate_endpoint_projection(&lease.endpoint_id);
        debug_assert!(activated, "preflighted endpoint projection must activate");
        debug_assert!(shell.endpoint_is_active(endpoints.active_id()));
        shell.set_pane_surface(surface);
        self.start_presentation_sync(endpoints, lease.clone(), completion)?;
        Ok(ActivationCompletion::AwaitingPresentationSync {
            previous: self.source.endpoint_id.clone(),
            endpoint: lease.endpoint_id,
        })
    }
}
use super::*;
