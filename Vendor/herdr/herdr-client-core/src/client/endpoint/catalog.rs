// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/endpoint/catalog.rs (1:1 6:10 12:15 18:82 91:101 160:274), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use super::ProfileId;

const CATALOG_VERSION: u32 = 1;
const MAX_CATALOG_BYTES: usize = 64 * 1024;
const MAX_PROFILES: usize = 64;
const MAX_LABEL_BYTES: usize = 128;
const MAX_TARGET_BYTES: usize = 1024;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SavedSshEndpoint {
    pub id: ProfileId,
    pub label: String,
    pub target: String,
    pub session: String,
    pub enabled: bool,
}

impl SavedSshEndpoint {
    pub fn new(
        label: impl Into<String>,
        target: impl Into<String>,
        session: impl Into<String>,
    ) -> Result<Self, String> {
        let profile = Self {
            id: ProfileId::generate(),
            label: label.into(),
            target: target.into(),
            session: session.into(),
            enabled: true,
        };
        profile.validate()?;
        Ok(profile)
    }

    fn validate(&self) -> Result<(), String> {
        ProfileId::parse(self.id.to_string())?;
        let label = self.label.trim();
        if label.is_empty() {
            return Err("SSH endpoint label cannot be empty".into());
        }
        if label.len() > MAX_LABEL_BYTES || label.chars().any(char::is_control) {
            return Err(format!(
                "SSH endpoint label must be at most {MAX_LABEL_BYTES} bytes and contain no control characters"
            ));
        }
        if self.target.len() > MAX_TARGET_BYTES || self.target.chars().any(char::is_control) {
            return Err(format!(
                "SSH target must be at most {MAX_TARGET_BYTES} bytes and contain no control characters"
            ));
        }
        super::validation::validate_remote_target(&self.target).map(|_| ())?;
        let authority = self.target.strip_prefix("ssh://").unwrap_or(&self.target);
        if authority
            .rsplit_once('@')
            .is_some_and(|(userinfo, _)| userinfo.contains(':'))
        {
            return Err("SSH target must not contain a password".into());
        }
        super::validation::validate_name(&self.session)?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EndpointCatalog {
    version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_profile: Option<ProfileId>,
    #[serde(default)]
    pub ssh: Vec<SavedSshEndpoint>,
}
impl Default for EndpointCatalog {
    fn default() -> Self {
        Self {
            version: CATALOG_VERSION,
            selected_profile: None,
            ssh: Vec::new(),
        }
    }
}

impl EndpointCatalog {
    pub fn add_ssh(
        &mut self,
        label: impl Into<String>,
        target: impl Into<String>,
        session: impl Into<String>,
    ) -> Result<ProfileId, String> {
        if self.ssh.len() >= MAX_PROFILES {
            return Err(format!("at most {MAX_PROFILES} SSH endpoints can be saved"));
        }
        let profile = SavedSshEndpoint::new(label, target, session)?;
        let id = profile.id.clone();
        self.ssh.push(profile);
        Ok(id)
    }

    pub fn rename_ssh(&mut self, id: &ProfileId, label: impl Into<String>) -> Result<bool, String> {
        let Some(index) = self.ssh.iter().position(|profile| &profile.id == id) else {
            return Ok(false);
        };
        let mut renamed = self.ssh[index].clone();
        renamed.label = label.into();
        renamed.validate()?;
        self.ssh[index] = renamed;
        Ok(true)
    }

    pub fn remove_ssh(&mut self, id: &ProfileId) -> bool {
        let previous_len = self.ssh.len();
        self.ssh.retain(|profile| &profile.id != id);
        if self.selected_profile.as_ref() == Some(id) {
            self.selected_profile = None;
        }
        self.ssh.len() != previous_len
    }

    pub fn select_home(&mut self) {
        self.selected_profile = None;
    }

    pub fn select_endpoint(&mut self, endpoint_id: &super::ClientEndpointId) -> bool {
        match endpoint_id {
            super::ClientEndpointId::Home => {
                self.select_home();
                true
            }
            super::ClientEndpointId::Ssh(profile_id) => self.select_ssh(profile_id),
        }
    }

    pub fn select_ssh(&mut self, id: &ProfileId) -> bool {
        if !self
            .ssh
            .iter()
            .any(|profile| &profile.id == id && profile.enabled)
        {
            return false;
        }
        self.selected_profile = Some(id.clone());
        true
    }

    pub fn has_enabled_ssh(&self) -> bool {
        self.ssh.iter().any(|profile| profile.enabled)
    }

    pub fn contains_enabled_target_session(&self, target: &str, session: &str) -> bool {
        self.ssh.iter().any(|profile| {
            profile.enabled && profile.target == target && profile.session == session
        })
    }

    pub fn set_enabled(&mut self, id: &ProfileId, enabled: bool) -> bool {
        let Some(profile) = self.ssh.iter_mut().find(|profile| &profile.id == id) else {
            return false;
        };
        profile.enabled = enabled;
        if !enabled && self.selected_profile.as_ref() == Some(id) {
            self.selected_profile = None;
        }
        true
    }

    fn validate(&self) -> Result<(), String> {
        if self.version != CATALOG_VERSION {
            return Err(format!(
                "unsupported endpoint catalog version {}; expected {CATALOG_VERSION}",
                self.version
            ));
        }
        if self.ssh.len() > MAX_PROFILES {
            return Err(format!(
                "endpoint catalog contains more than {MAX_PROFILES} SSH profiles"
            ));
        }
        let mut ids = HashSet::new();
        for profile in &self.ssh {
            profile.validate()?;
            if !ids.insert(profile.id.clone()) {
                return Err(format!("duplicate endpoint profile id {}", profile.id));
            }
        }
        if self.selected_profile.as_ref().is_some_and(|selected| {
            !self
                .ssh
                .iter()
                .any(|profile| &profile.id == selected && profile.enabled)
        }) {
            return Err("selected SSH endpoint is absent or disabled in the catalog".into());
        }
        Ok(())
    }
}

#[path = "catalog_codec.rs"]
mod codec;
