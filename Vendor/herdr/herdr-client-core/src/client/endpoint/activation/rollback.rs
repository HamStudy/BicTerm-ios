// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (679:817), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    /// Losing the source revokes its surface and removes the rollback destination; it must not
    /// cancel a healthy target. Losing the target restores the source when it is still available.
    pub fn endpoint_disconnected(
        &mut self,
        endpoints: &mut EndpointRegistry,
        endpoint_id: &ClientEndpointId,
        error: String,
    ) -> ActivationRollback {
        self.rollback_error = Some(error.clone());
        if self.target.endpoint_id == *endpoint_id && self.source.endpoint_id != *endpoint_id {
            return match self.phase {
                ActivationPhase::RestoringSource { .. } => ActivationRollback::Pending,
                _ => match self.start_source_restore(endpoints, self.resize.clone()) {
                    Ok(()) => ActivationRollback::Pending,
                    Err(restore_error) => ActivationRollback::Unavailable(format!(
                        "{error}; source endpoint could not be restored safely: {restore_error}"
                    )),
                },
            };
        }
        if self.source.endpoint_id != *endpoint_id {
            return ActivationRollback::Unavailable(error);
        }
        self.source_available = false;
        if self.source.endpoint_id != self.target.endpoint_id {
            match &self.phase {
                ActivationPhase::ReleasingSource { .. } => {
                    return match self.start_target(endpoints, self.resize.clone()) {
                        Ok(()) => ActivationRollback::Pending,
                        Err(message) => ActivationRollback::Unavailable(message),
                    };
                }
                ActivationPhase::ActivatingTarget { .. } => return ActivationRollback::Pending,
                ActivationPhase::SynchronizingPresentation { lease, .. }
                | ActivationPhase::AwaitingPresentationEffects { lease, .. }
                    if lease.endpoint_id == self.target.endpoint_id =>
                {
                    return ActivationRollback::Pending
                }
                _ => {}
            }
        }
        match self.phase {
            ActivationPhase::ReleasingSource { .. } => ActivationRollback::Unavailable(error),
            ActivationPhase::ActivatingTarget { .. } => {
                match self.start_target_release(endpoints) {
                    Ok(()) => ActivationRollback::Pending,
                    Err(release_error) => ActivationRollback::Unavailable(format!(
                        "{error}; target endpoint could not be released safely: {release_error}"
                    )),
                }
            }
            ActivationPhase::ReleasingTargetForRollback { .. } => ActivationRollback::Pending,
            ActivationPhase::RestoringSource { .. } => ActivationRollback::Unavailable(error),
            ActivationPhase::SynchronizingPresentation { ref lease, .. }
            | ActivationPhase::AwaitingPresentationEffects { ref lease, .. } => {
                if lease.endpoint_id == self.target.endpoint_id {
                    match self.start_target_release(endpoints) {
                        Ok(()) => ActivationRollback::Pending,
                        Err(release_error) => ActivationRollback::Unavailable(format!(
                            "{error}; target endpoint could not be released safely: {release_error}"
                        )),
                    }
                } else {
                    ActivationRollback::Unavailable(error)
                }
            }
        }
    }

    pub fn rollback(
        &mut self,
        endpoints: &mut EndpointRegistry,
        error: String,
        source_release_rejected: bool,
    ) -> ActivationRollback {
        self.rollback_error = Some(error.clone());
        if matches!(self.phase, ActivationPhase::ReleasingSource { .. }) && source_release_rejected
        {
            // Rejection proves source-off did not commit, but cached source metadata may have
            // advanced while the frame was frozen. Restore through the same coherent on/sync
            // path rather than immediately exposing a stale source projection.
            return match self.start_source_restore(endpoints, self.resize.clone()) {
                Ok(()) => ActivationRollback::Pending,
                Err(restore_error) => ActivationRollback::Unavailable(format!(
                    "{error}; source endpoint could not resume: {restore_error}"
                )),
            };
        }
        let result = match self.phase {
            ActivationPhase::ReleasingSource { .. } => {
                if self.source_available {
                    self.start_source_restore(endpoints, self.resize.clone())
                } else {
                    Err("the previous endpoint is no longer connected".into())
                }
            }
            ActivationPhase::ActivatingTarget { .. } => self.start_target_release(endpoints),
            ActivationPhase::ReleasingTargetForRollback { .. } => {
                // The target may have observed target-on or target-off. Closing this transport
                // is the only safe local revocation when target-off is not acknowledged.
                endpoints.fail(
                    &self.target.endpoint_id,
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "endpoint did not acknowledge surface revocation",
                    ),
                );
                if !self.source_available {
                    return ActivationRollback::Unavailable(format!(
                        "{error}; the target connection was closed because no presentation owner could be proven"
                    ));
                }
                self.start_source_restore(endpoints, self.resize.clone())
            }
            ActivationPhase::RestoringSource { .. } => {
                return ActivationRollback::Unavailable(format!(
                    "{error}; source endpoint could not be restored"
                ));
            }
            ActivationPhase::SynchronizingPresentation { ref lease, .. }
            | ActivationPhase::AwaitingPresentationEffects { ref lease, .. } => {
                if lease.endpoint_id == self.target.endpoint_id {
                    self.start_target_release(endpoints)
                } else {
                    return ActivationRollback::Unavailable(format!(
                        "{error}; source endpoint presentation could not be synchronized"
                    ));
                }
            }
        };
        match result {
            Ok(()) => ActivationRollback::Pending,
            Err(rollback_error) => ActivationRollback::Unavailable(format!(
                "{error}; source endpoint could not be restored safely: {rollback_error}"
            )),
        }
    }
}
use super::*;
