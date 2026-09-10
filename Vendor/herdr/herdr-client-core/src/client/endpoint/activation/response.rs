// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (295:441), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    pub fn receive_response_for_boot(
        &mut self,
        endpoint_id: &ClientEndpointId,
        generation: u64,
        boot_id: &str,
        request_id: &str,
        data: &[u8],
        endpoints: &mut EndpointRegistry,
    ) -> SurfaceActivationProgress {
        if !self.accepts_response(endpoint_id, generation, boot_id, request_id) {
            return SurfaceActivationProgress::Stale;
        }
        let result = match decode_endpoint_response(request_id, data) {
            Ok(result) => result,
            Err(error) => {
                return SurfaceActivationProgress::Rejected {
                    source_release_rejected: matches!(
                        self.phase,
                        ActivationPhase::ReleasingSource { .. }
                    ) && error.code.is_some(),
                    message: error.message,
                };
            }
        };
        match &mut self.phase {
            ActivationPhase::ReleasingSource { .. } => {
                if let Err(message) = surface_set_revision(&result, false) {
                    return SurfaceActivationProgress::Rejected {
                        message,
                        source_release_rejected: false,
                    };
                }
                if let Err(message) = self.start_target(endpoints, self.resize.clone()) {
                    return SurfaceActivationProgress::Rejected {
                        message,
                        source_release_rejected: false,
                    };
                }
                SurfaceActivationProgress::Pending
            }
            ActivationPhase::ActivatingTarget {
                request_id: surface_request_id,
                acknowledged_revision,
                ..
            } if surface_request_id == request_id => {
                let revision = match surface_set_revision(&result, true) {
                    Ok(revision) => revision,
                    Err(message) => {
                        return SurfaceActivationProgress::Rejected {
                            message,
                            source_release_rejected: false,
                        };
                    }
                };
                *acknowledged_revision = Some(revision);
                self.progress()
            }
            ActivationPhase::ActivatingTarget {
                focus_request_id,
                focus_request_target,
                focus_acknowledged,
                ..
            } if focus_request_id.as_deref() == Some(request_id) => {
                let requested = focus_request_target.clone();
                let Some(requested) = requested else {
                    return SurfaceActivationProgress::Stale;
                };
                if !focus_result_matches(Some(&requested), &result) {
                    return SurfaceActivationProgress::Rejected {
                        message: "endpoint focus returned an unexpected result".into(),
                        source_release_rejected: false,
                    };
                }
                *focus_request_id = None;
                *focus_request_target = None;
                if self.focus != Some(requested) {
                    *focus_acknowledged = false;
                    if let Err(message) = self.send_latest_focus(endpoints) {
                        return SurfaceActivationProgress::Rejected {
                            message,
                            source_release_rejected: false,
                        };
                    }
                    return self.progress();
                }
                *focus_acknowledged = true;
                self.progress()
            }
            ActivationPhase::ReleasingTargetForRollback { .. } => {
                if let Err(message) = surface_set_revision(&result, false) {
                    return SurfaceActivationProgress::Rejected {
                        message,
                        source_release_rejected: false,
                    };
                }
                endpoints.set_surface_active(&self.target.endpoint_id, false);
                if !self.source_available {
                    return SurfaceActivationProgress::Rejected {
                        message: self.rollback_error.clone().unwrap_or_else(|| {
                            "the previous endpoint is no longer connected".into()
                        }),
                        source_release_rejected: false,
                    };
                }
                if let Err(message) = self.start_source_restore(endpoints, self.resize.clone()) {
                    return SurfaceActivationProgress::Rejected {
                        message,
                        source_release_rejected: false,
                    };
                }
                SurfaceActivationProgress::Pending
            }
            ActivationPhase::RestoringSource {
                acknowledged_revision,
                ..
            } => {
                let revision = match surface_set_revision(&result, true) {
                    Ok(revision) => revision,
                    Err(message) => {
                        return SurfaceActivationProgress::Rejected {
                            message,
                            source_release_rejected: false,
                        };
                    }
                };
                *acknowledged_revision = Some(revision);
                self.progress()
            }
            ActivationPhase::SynchronizingPresentation {
                acknowledged_revision,
                ..
            } => {
                let revision = match surface_set_revision(&result, true) {
                    Ok(revision) => revision,
                    Err(message) => {
                        return SurfaceActivationProgress::Rejected {
                            message,
                            source_release_rejected: false,
                        };
                    }
                };
                *acknowledged_revision = Some(revision);
                self.progress()
            }
            _ => SurfaceActivationProgress::Stale,
        }
    }
}
use super::*;
