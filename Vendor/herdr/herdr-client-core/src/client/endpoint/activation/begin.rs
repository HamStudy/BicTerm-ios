// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/activation.rs (17:142), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
impl PendingEndpointActivation {
    #[allow(clippy::too_many_arguments)]
    pub fn begin(
        shell: &crate::client::shell::ClientShellState,
        endpoints: &mut EndpointRegistry,
        target: ClientEndpointId,
        focus: Option<crate::client::shell::ClientEndpointFocusTarget>,
        resize: crate::protocol::ClientMessage,
        serial: u64,
        now: Instant,
    ) -> Result<Self, ActivationBeginError> {
        resize_geometry(&resize).ok_or_else(|| {
            ActivationBeginError::Preflight(
                "endpoint activation did not include a surface resize".to_owned(),
            )
        })?;
        let source_id = endpoints.active_id().clone();
        let source_has_live_surface = endpoints
            .connection(&source_id)
            .is_some_and(|connection| connection.surface_active);
        let (source, source_available) = if source_has_live_surface {
            (
                endpoint_lease(shell, endpoints, &source_id)
                    .map_err(ActivationBeginError::Preflight)?,
                true,
            )
        } else {
            (disconnected_endpoint_lease(shell, &source_id), false)
        };
        let target_lease =
            endpoint_lease(shell, endpoints, &target).map_err(ActivationBeginError::Preflight)?;
        let source_compatible = !source_available
            || endpoints
                .connection(&source_id)
                .is_some_and(|connection| connection.negotiation.supports_surface_interest());
        let target_compatible = endpoints
            .connection(&target)
            .is_some_and(|connection| connection.negotiation.supports_surface_interest());
        if !source_compatible || !target_compatible {
            return Err(ActivationBeginError::Preflight(
                "endpoint must be updated before it can join the selected surface".into(),
            ));
        }

        let source_is_target = source.endpoint_id == target_lease.endpoint_id;
        // Validate every typed lifecycle and optional focus envelope before the first transport
        // write. Any error above this line is guaranteed not to have changed either endpoint.
        let source_release_request = (source_available && !source_is_target)
            .then(|| {
                surface_interest_request(
                    &source.boot_id,
                    format!("client-shell-surface:{serial}:off"),
                    false,
                )
            })
            .transpose()
            .map_err(|error| ActivationBeginError::Preflight(error.to_string()))?;
        surface_interest_request(
            &target_lease.boot_id,
            format!("client-shell-surface:{serial}:on"),
            true,
        )
        .map_err(|error| ActivationBeginError::Preflight(error.to_string()))?;
        if let Some(target) = focus.as_ref() {
            focus_request(
                &target_lease.boot_id,
                format!("client-shell-focus:{serial}:1"),
                target,
            )
            .map_err(|error| ActivationBeginError::Preflight(error.to_string()))?;
        }

        endpoints.freeze_input();
        let mut activation = Self {
            source,
            source_available,
            target: target_lease,
            focus,
            host_focused: shell.host_focus_baseline(),
            resize: resize.clone(),
            phase: ActivationPhase::ReleasingSource {
                request_id: format!("client-shell-surface:{serial}:off"),
            },
            deadline: now + ACTIVATION_TIMEOUT,
            epoch: serial,
            next_focus_serial: 0,
            rollback_error: None,
            successor: None,
        };

        // Reconnecting the selected endpoint has no live source surface to release. All normal
        // handoffs must make the source locally inactive before a target request is even sent.
        if source_is_target || !source_available {
            if let Err(error) = activation.start_target(endpoints, resize) {
                return Err(ActivationBeginError::Partial {
                    activation: Box::new(activation),
                    error,
                });
            }
        } else {
            // `surface.set(false)` removes the viewer, but old servers only emit the PTY focus
            // loss while the viewer is still active. Revoke it explicitly before source-off.
            if endpoints.send_to(
                &activation.source.endpoint_id,
                &crate::protocol::ClientMessage::ClientShellFocus { focused: false },
            ) != EndpointSendOutcome::Sent
            {
                return Err(ActivationBeginError::Partial {
                    activation: Box::new(activation),
                    error: "source endpoint focus revoke could not be sent".into(),
                });
            }
            let request = source_release_request.expect("validated source release request");
            if endpoints.send_to(&activation.source.endpoint_id, &request)
                != EndpointSendOutcome::Sent
            {
                return Err(ActivationBeginError::Partial {
                    activation: Box::new(activation),
                    error: "source endpoint release could not be sent".into(),
                });
            }
            // This is deliberately before the acknowledgement: the source is no longer viewed
            // locally while its release is in flight, and pane input is consequently blocked.
            endpoints.set_surface_active(&activation.source.endpoint_id, false);
        }
        Ok(activation)
    }
}
use super::*;
