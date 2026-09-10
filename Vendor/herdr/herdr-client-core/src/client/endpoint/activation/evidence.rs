// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (443:678), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    pub fn receive_snapshot(
        &mut self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        snapshot: &crate::protocol::ClientShellSnapshot,
    ) -> SurfaceActivationProgress {
        let lease = match &self.phase {
            ActivationPhase::ActivatingTarget { .. } => &self.target,
            ActivationPhase::RestoringSource { .. } => &self.source,
            ActivationPhase::SynchronizingPresentation { lease, .. } => lease,
            _ => return SurfaceActivationProgress::Stale,
        };
        if !endpoint_matches(lease, endpoint_id, generation, &snapshot.boot_id)
            || snapshot.revision < lease.minimum_revision
        {
            return SurfaceActivationProgress::Stale;
        }
        let evidence = match &mut self.phase {
            ActivationPhase::ActivatingTarget { evidence, .. }
                if endpoint_matches(&self.target, endpoint_id, generation, &snapshot.boot_id) =>
            {
                evidence
            }
            ActivationPhase::RestoringSource { evidence, .. }
                if endpoint_matches(&self.source, endpoint_id, generation, &snapshot.boot_id) =>
            {
                evidence
            }
            ActivationPhase::SynchronizingPresentation {
                lease, evidence, ..
            } if endpoint_matches(lease, endpoint_id, generation, &snapshot.boot_id) => evidence,
            _ => return SurfaceActivationProgress::Stale,
        };
        evidence.record_snapshot(snapshot);
        self.progress()
    }

    pub fn receive_surface(
        &mut self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        surface: crate::protocol::PaneSurfaceFrame,
    ) -> SurfaceActivationProgress {
        let lease = match &self.phase {
            ActivationPhase::ActivatingTarget { .. } => &self.target,
            ActivationPhase::RestoringSource { .. } => &self.source,
            ActivationPhase::SynchronizingPresentation { lease, .. } => lease,
            _ => return SurfaceActivationProgress::Stale,
        };
        if !endpoint_matches(lease, endpoint_id, generation, &surface.boot_id) {
            return SurfaceActivationProgress::Stale;
        }
        if !surface_matches_geometry(&surface, self.geometry()) {
            return SurfaceActivationProgress::Pending;
        }
        match &mut self.phase {
            ActivationPhase::ActivatingTarget { evidence, .. }
            | ActivationPhase::RestoringSource { evidence, .. }
            | ActivationPhase::SynchronizingPresentation { evidence, .. } => {
                evidence.record_surface(surface)
            }
            _ => unreachable!("checked activation phase"),
        }
        self.progress()
    }

    pub fn receive_presentation_effects_ready(
        &mut self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        token: &str,
    ) -> SurfaceActivationProgress {
        let ActivationPhase::AwaitingPresentationEffects {
            lease,
            token: expected,
            ready,
            ..
        } = &mut self.phase
        else {
            return SurfaceActivationProgress::Stale;
        };
        if lease.endpoint_id != *endpoint_id || lease.generation != generation || expected != token
        {
            return SurfaceActivationProgress::Stale;
        }
        *ready = true;
        SurfaceActivationProgress::Ready
    }

    /// A same-endpoint navigation request replaces the desired target but never joins the
    /// in-flight focus RPC. Once that request resolves, `send_latest_focus` sends only the most
    /// recent desired target.
    pub fn retarget(
        &mut self,
        focus: Option<crate::client::shell::ClientEndpointFocusTarget>,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        self.focus = focus;
        if let ActivationPhase::ActivatingTarget {
            focus_request_id,
            focus_acknowledged,
            ..
        } = &mut self.phase
        {
            *focus_acknowledged = self.focus.is_none() && focus_request_id.is_none();
        } else {
            // The latest target is retained and will be sent immediately after source release.
            return Ok(());
        }
        self.send_latest_focus(endpoints)
    }

    pub fn update_resize(
        &mut self,
        resize: crate::protocol::ClientMessage,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        resize_geometry(&resize)
            .ok_or_else(|| "endpoint activation did not include a surface resize".to_owned())?;
        self.resize = resize.clone();
        let restart_effects_fence = match &self.phase {
            ActivationPhase::AwaitingPresentationEffects {
                lease, completion, ..
            } => Some((lease.clone(), (**completion).clone())),
            _ => None,
        };
        if let Some((lease, completion)) = restart_effects_fence {
            if endpoints.send_to(&lease.endpoint_id, &resize) != EndpointSendOutcome::Sent {
                return Err("pending endpoint resize could not be sent".into());
            }
            return self.start_presentation_sync(endpoints, lease, completion);
        }
        match &mut self.phase {
            ActivationPhase::ActivatingTarget { evidence, .. }
            | ActivationPhase::RestoringSource { evidence, .. }
            | ActivationPhase::SynchronizingPresentation { evidence, .. } => {
                evidence.invalidate_surface()
            }
            _ => {}
        }
        let destination = match &self.phase {
            ActivationPhase::ActivatingTarget { .. } => Some(&self.target.endpoint_id),
            ActivationPhase::RestoringSource { .. } => Some(&self.source.endpoint_id),
            ActivationPhase::SynchronizingPresentation { lease, .. } => Some(&lease.endpoint_id),
            _ => None,
        };
        if let Some(destination) = destination {
            if endpoints.send_to(destination, &resize) != EndpointSendOutcome::Sent {
                return Err("pending endpoint resize could not be sent".into());
            }
        }
        Ok(())
    }

    pub fn update_host_focus(
        &mut self,
        focused: bool,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        self.host_focused = focused;
        let restart = self.presentation_restart();
        let destination = match &self.phase {
            ActivationPhase::ActivatingTarget { .. } => Some(&self.target.endpoint_id),
            ActivationPhase::RestoringSource { .. } => Some(&self.source.endpoint_id),
            ActivationPhase::SynchronizingPresentation { lease, .. }
            | ActivationPhase::AwaitingPresentationEffects { lease, .. } => {
                Some(&lease.endpoint_id)
            }
            _ => None,
        };
        if let Some(destination) = destination {
            if endpoints.send_to(
                destination,
                &crate::protocol::ClientMessage::ClientShellFocus { focused },
            ) != EndpointSendOutcome::Sent
            {
                return Err("pending endpoint focus baseline could not be sent".into());
            }
        }
        if let Some((lease, completion)) = restart {
            self.start_presentation_sync(endpoints, lease, completion)?;
        } else {
            self.invalidate_current_evidence();
        }
        Ok(())
    }

    pub fn update_host_theme(
        &mut self,
        update: crate::protocol::ClientHostThemeUpdate,
        endpoints: &mut EndpointRegistry,
    ) -> Result<(), String> {
        let restart = self.presentation_restart();
        let destination = match &self.phase {
            ActivationPhase::ActivatingTarget { .. } => Some(&self.target.endpoint_id),
            ActivationPhase::RestoringSource { .. } => Some(&self.source.endpoint_id),
            ActivationPhase::SynchronizingPresentation { lease, .. }
            | ActivationPhase::AwaitingPresentationEffects { lease, .. } => {
                Some(&lease.endpoint_id)
            }
            _ => None,
        };
        if let Some(destination) = destination {
            let message = crate::protocol::ClientMessage::ClientShellHostTheme { update };
            if endpoints.send_to(destination, &message) != EndpointSendOutcome::Sent {
                return Err("pending endpoint host theme could not be sent".into());
            }
        }
        if let Some((lease, completion)) = restart {
            self.start_presentation_sync(endpoints, lease, completion)?;
        } else {
            self.invalidate_current_evidence();
        }
        Ok(())
    }

    pub(super) fn presentation_restart(&self) -> Option<(EndpointLease, ActivationCompletion)> {
        match &self.phase {
            ActivationPhase::SynchronizingPresentation {
                lease, completion, ..
            }
            | ActivationPhase::AwaitingPresentationEffects {
                lease, completion, ..
            } => Some((lease.clone(), (**completion).clone())),
            _ => None,
        }
    }

    pub(super) fn invalidate_current_evidence(&mut self) {
        match &mut self.phase {
            ActivationPhase::ActivatingTarget { evidence, .. }
            | ActivationPhase::RestoringSource { evidence, .. } => evidence.invalidate_surface(),
            _ => {}
        }
    }
}
use super::*;
