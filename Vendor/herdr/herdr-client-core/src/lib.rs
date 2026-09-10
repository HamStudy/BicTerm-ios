//! Transport-neutral endpoint state. The caller owns connection I/O and presentation.
pub use herdr_protocol as protocol;
pub mod api;
pub mod client;
pub mod handshake;
pub mod outbound;
pub mod surface;
pub use client::endpoint::*;
pub use client::shell::{ClientEndpointFocusTarget, ClientShellState};
