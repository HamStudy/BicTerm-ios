mod activation;
mod catalog;
mod health;
mod identity;
mod message_policy;
mod registry;
mod supervisor;
mod validation;
pub use activation::*;
pub use catalog::*;
pub use identity::*;
pub use message_policy::*;
pub use registry::*;
pub use supervisor::*;

#[cfg(test)]
fn test_source() -> ClientEndpointId {
    ClientEndpointId::Ssh(ProfileId::parse("11111111111111111111111111111111").unwrap())
}
