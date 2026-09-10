// Adapted from upstream endpoint/supervisor.rs: caller executes connection attempts.
use super::{ClientEndpointId, ClientEndpointStatus, SavedSshEndpoint};
use std::collections::HashMap;
use std::time::{Duration, Instant};

struct ReconnectState {
    profile: SavedSshEndpoint,
    attempts: u32,
    next_attempt: Option<Instant>,
    in_flight: bool,
    generation: Option<u64>,
}

pub struct ConnectionAttempt {
    pub endpoint: ClientEndpointId,
    pub generation: u64,
    pub profile: SavedSshEndpoint,
}

pub struct EndpointSupervisors {
    endpoints: HashMap<ClientEndpointId, ReconnectState>,
    next_generation: u64,
}

impl EndpointSupervisors {
    pub fn new(profiles: &[SavedSshEndpoint], now: Instant) -> Self {
        let mut result = Self {
            endpoints: HashMap::new(),
            next_generation: 1,
        };
        result.reconcile_profiles(profiles, now);
        result
    }

    pub fn reconcile_profiles(
        &mut self,
        profiles: &[SavedSshEndpoint],
        now: Instant,
    ) -> Vec<ClientEndpointId> {
        let mut retired = Vec::new();
        self.endpoints.retain(|id, state| {
            let keep = profiles.iter().any(|p| {
                p.enabled
                    && p.id == state.profile.id
                    && p.target == state.profile.target
                    && p.session == state.profile.session
            });
            if !keep {
                retired.push(id.clone());
            }
            keep
        });
        for profile in profiles.iter().filter(|p| p.enabled) {
            let state = self
                .endpoints
                .entry(ClientEndpointId::Ssh(profile.id.clone()))
                .or_insert_with(|| ReconnectState {
                    profile: profile.clone(),
                    attempts: 0,
                    next_attempt: Some(now),
                    in_flight: false,
                    generation: None,
                });
            state.profile = profile.clone();
        }
        retired
    }

    pub fn poll_due(&mut self, now: Instant, maximum_in_flight: usize) -> Vec<ConnectionAttempt> {
        let running = self
            .endpoints
            .values()
            .filter(|state| state.in_flight)
            .count();
        let mut remaining = maximum_in_flight.saturating_sub(running);
        let mut attempts = Vec::new();
        for (endpoint, state) in &mut self.endpoints {
            if remaining == 0 {
                break;
            }
            if state.in_flight || state.next_attempt.is_none_or(|deadline| deadline > now) {
                continue;
            }
            let Some(next) = self.next_generation.checked_add(1) else {
                break;
            };
            let generation = self.next_generation;
            self.next_generation = next;
            state.generation = Some(generation);
            state.in_flight = true;
            state.next_attempt = None;
            remaining -= 1;
            attempts.push(ConnectionAttempt {
                endpoint: endpoint.clone(),
                generation,
                profile: state.profile.clone(),
            });
        }
        attempts
    }

    pub fn record_status(
        &mut self,
        attempt: &ConnectionAttempt,
        status: ClientEndpointStatus,
        now: Instant,
    ) -> bool {
        let Some(state) = self.endpoints.get_mut(&attempt.endpoint) else {
            return false;
        };
        if state.generation != Some(attempt.generation) {
            return false;
        }
        state.in_flight = false;
        match status {
            ClientEndpointStatus::Online => {
                state.attempts = 0;
                state.next_attempt = None;
            }
            ClientEndpointStatus::Attention | ClientEndpointStatus::Disabled => {
                state.next_attempt = None
            }
            ClientEndpointStatus::Connecting | ClientEndpointStatus::Reconnecting => {
                state.attempts = state.attempts.saturating_add(1);
                let factor = 1_u32 << state.attempts.saturating_sub(1).min(6);
                state.next_attempt = Some(
                    now + Duration::from_millis(500)
                        .saturating_mul(factor)
                        .min(Duration::from_secs(30)),
                );
            }
        }
        true
    }
}
