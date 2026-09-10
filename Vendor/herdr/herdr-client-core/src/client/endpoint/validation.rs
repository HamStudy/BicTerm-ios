// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/remote/args.rs (118:126), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
pub fn validate_remote_target(target: &str) -> Result<&str, String> {
    if target.is_empty() {
        return Err("missing value for --remote".to_string());
    }
    if target.starts_with('-') {
        return Err("--remote target must not start with '-'".to_string());
    }
    Ok(target)
}

const MAX_SESSION_NAME_LEN: usize = 64;

include!("session_validation.rs");
