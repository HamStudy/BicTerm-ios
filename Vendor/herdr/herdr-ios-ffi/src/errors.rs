//! Handshake-error translation into structured FFI codes.
use crate::{
    FfiError, HERDR_CODE_HANDSHAKE_EXPECTED_WELCOME, HERDR_CODE_HANDSHAKE_INCOMPATIBLE,
    HERDR_CODE_HANDSHAKE_INVALID_WELCOME, HERDR_CODE_HANDSHAKE_REJECTED,
    HERDR_CODE_HANDSHAKE_TIMED_OUT,
};
use herdr_client_core::handshake::HandshakeError;

pub(crate) fn handshake_error(error: HandshakeError) -> FfiError {
    let code = match &error {
        HandshakeError::TimedOut => HERDR_CODE_HANDSHAKE_TIMED_OUT,
        HandshakeError::ExpectedWelcome => HERDR_CODE_HANDSHAKE_EXPECTED_WELCOME,
        HandshakeError::InvalidWelcome => HERDR_CODE_HANDSHAKE_INVALID_WELCOME,
        HandshakeError::Incompatible => HERDR_CODE_HANDSHAKE_INCOMPATIBLE,
        HandshakeError::Rejected(_) => HERDR_CODE_HANDSHAKE_REJECTED,
    };
    let detail = match error {
        HandshakeError::Rejected(message) => format!("server rejected the hello: {message}"),
        other => format!("{other:?}"),
    };
    FfiError::new(code, detail)
}
