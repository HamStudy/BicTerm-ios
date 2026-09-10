use super::*;

impl EndpointCatalog {
    pub fn from_json(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_CATALOG_BYTES {
            return Err("endpoint catalog exceeds the storage limit".into());
        }
        let catalog: Self = serde_json::from_slice(bytes)
            .map_err(|error| format!("invalid endpoint catalog: {error}"))?;
        catalog.validate()?;
        Ok(catalog)
    }

    pub fn to_json(&self) -> Result<Vec<u8>, String> {
        self.validate()?;
        serde_json::to_vec(self).map_err(|error| error.to_string())
    }
}
