// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (921:1147), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    pub(super) fn start_target(
        &mut self,
        endpoints: &mut EndpointRegistry,
        resize: crate::protocol::ClientMessage,
    ) -> Result<(), String> {
        let request_id = format!("client-shell-surface:{}:on", self.epoch);
        self.deadline = Instant::now() + ACTIVATION_TIMEOUT;
        // A transport may fail after writing any baseline or surface message. Enter the target
        // phase first so every uncertain target write is reversed through target-off before
        // source restoration is considered.
        self.phase = ActivationPhase::ActivatingTarget {
            request_id: request_id.clone(),
            acknowledged_revision: None,
            focus_request_id: None,
            focus_request_target: None,
            focus_acknowledged: self.focus.is_none(),
            evidence: ActivationEvidence::default(),
        };
        send_surface_activation(
            endpoints,
            &self.target,
            request_id,
            &resize,
            self.host_focused,
        )?;

        // From this point the target may have processed surface.set(true). Optional navigation
        // is serialized through one coalescing focus lane.
        self.send_latest_focus(endpoints)
    }

    pub(super) fn start_presentation_sync(
        &mut self,
        endpoints: &mut EndpointRegistry,
        lease: EndpointLease,
        completion: ActivationCompletion,
    ) -> Result<(), String> {
        let request_id = format!("client-shell-surface:{}:presentation-sync", self.epoch);
        let request = surface_interest_request(&lease.boot_id, request_id.clone(), true)
            .map_err(|error| error.to_string())?;
        self.phase = ActivationPhase::SynchronizingPresentation {
            lease: lease.clone(),
            request_id,
            acknowledged_revision: None,
            evidence: ActivationEvidence::default(),
            completion: Box::new(completion),
        };
        self.deadline = Instant::now() + ACTIVATION_TIMEOUT;
        if endpoints.send_to(&lease.endpoint_id, &request) != EndpointSendOutcome::Sent {
            return Err("endpoint presentation synchronization could not be sent".into());
        }
        Ok(())
    }

    pub(super) fn start_presentation_effects_fence(
        &mut self,
        endpoints: &mut EndpointRegistry,
        lease: EndpointLease,
        completion: ActivationCompletion,
    ) -> Result<(), String> {
        let token = format!("{}:{}:{}", self.epoch, lease.generation, lease.boot_id);
        self.phase = ActivationPhase::AwaitingPresentationEffects {
            lease: lease.clone(),
            token: token.clone(),
            ready: false,
            completion: Box::new(completion),
        };
        self.deadline = Instant::now() + ACTIVATION_TIMEOUT;
        let message = crate::protocol::ClientMessage::EndpointControl {
            kind: crate::protocol::endpoint::PRESENTATION_EFFECTS_SYNC_KIND.into(),
            data: token,
        };
        if endpoints.send_to(&lease.endpoint_id, &message) != EndpointSendOutcome::Sent {
            return Err("endpoint presentation effects fence could not be sent".into());
        }
        Ok(())
    }

    pub(super) fn start_target_release(
        &mut self,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        let request_id = format!("client-shell-surface:{}:rollback-target-off", self.epoch);
        let request = surface_interest_request(&self.target.boot_id, request_id.clone(), false)
            .map_err(|error| error.to_string())?;
        // Set the rollback phase before the potentially observed target-off write.
        self.phase = ActivationPhase::ReleasingTargetForRollback { request_id };
        self.deadline = Instant::now() + ACTIVATION_TIMEOUT;
        if endpoints.send_to(&self.target.endpoint_id, &request) != EndpointSendOutcome::Sent {
            return Err("target endpoint release could not be sent".into());
        }
        Ok(())
    }

    pub(super) fn start_source_restore(
        &mut self,
        endpoints: &mut EndpointRegistry,
        resize: crate::protocol::ClientMessage,
    ) -> Result<(), String> {
        let request_id = format!("client-shell-surface:{}:rollback-source-on", self.epoch);
        // Source baseline writes can also be observed before their send reports an error.
        self.phase = ActivationPhase::RestoringSource {
            request_id: request_id.clone(),
            acknowledged_revision: None,
            evidence: ActivationEvidence::default(),
        };
        self.deadline = Instant::now() + ACTIVATION_TIMEOUT;
        send_surface_activation(
            endpoints,
            &self.source,
            request_id,
            &resize,
            self.host_focused,
        )
    }

    pub(super) fn send_latest_focus(
        &mut self,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        let desired = self.focus.clone();
        let Some(desired) = desired else {
            if let ActivationPhase::ActivatingTarget {
                focus_request_id,
                focus_acknowledged,
                ..
            } = &mut self.phase
            {
                if focus_request_id.is_none() {
                    *focus_acknowledged = true;
                }
            }
            return Ok(());
        };
        if !matches!(
            &self.phase,
            ActivationPhase::ActivatingTarget {
                focus_request_id: None,
                ..
            }
        ) {
            return Ok(());
        }
        let request_id = self
            .next_focus_request_id()
            .expect("desired focus creates a request id");
        if let ActivationPhase::ActivatingTarget {
            focus_request_id,
            focus_request_target,
            focus_acknowledged,
            ..
        } = &mut self.phase
        {
            *focus_acknowledged = false;
            *focus_request_id = Some(request_id.clone());
            *focus_request_target = Some(desired.clone());
        }
        let request = focus_request(&self.target.boot_id, request_id, &desired)
            .map_err(|error| error.to_string())?;
        if endpoints.send_to(&self.target.endpoint_id, &request) != EndpointSendOutcome::Sent {
            return Err("endpoint focus could not be sent".into());
        }
        Ok(())
    }

    pub(super) fn next_focus_request_id(&mut self) -> Option<String> {
        self.focus.as_ref()?;
        self.next_focus_serial = self.next_focus_serial.saturating_add(1);
        Some(format!(
            "client-shell-focus:{}:{}",
            self.epoch, self.next_focus_serial
        ))
    }

    pub(super) fn progress(&self) -> SurfaceActivationProgress {
        match &self.phase {
            ActivationPhase::ActivatingTarget {
                acknowledged_revision,
                focus_acknowledged,
                evidence,
                ..
            } if acknowledged_revision.is_some_and(|revision| {
                *focus_acknowledged
                    && evidence
                        .coherent_surface(revision, self.geometry())
                        .is_some_and(|surface| self.target_matches(surface))
            }) =>
            {
                SurfaceActivationProgress::Ready
            }
            ActivationPhase::RestoringSource {
                acknowledged_revision,
                evidence,
                ..
            }
            | ActivationPhase::SynchronizingPresentation {
                acknowledged_revision,
                evidence,
                ..
            } if acknowledged_revision.is_some_and(|revision| {
                evidence
                    .coherent_surface(revision, self.geometry())
                    .is_some()
            }) =>
            {
                SurfaceActivationProgress::Ready
            }
            _ => SurfaceActivationProgress::Pending,
        }
    }

    pub(super) fn target_matches(&self, surface: &crate::protocol::PaneSurfaceFrame) -> bool {
        let evidence = match &self.phase {
            ActivationPhase::ActivatingTarget { evidence, .. } => evidence,
            _ => return false,
        };
        match &self.focus {
            Some(crate::client::shell::ClientEndpointFocusTarget::Pane(pane_id)) => {
                evidence.focused_pane_id.as_deref() == Some(pane_id)
                    && surface
                        .panes
                        .iter()
                        .any(|pane| pane.focused && &pane.pane_id == pane_id)
            }
            Some(crate::client::shell::ClientEndpointFocusTarget::Tab(tab_id)) => {
                evidence.focused_tab_id.as_deref() == Some(tab_id)
            }
            Some(crate::client::shell::ClientEndpointFocusTarget::Workspace(workspace_id)) => {
                evidence.focused_workspace_id.as_deref() == Some(workspace_id)
            }
            None => true,
        }
    }
}
use super::*;
