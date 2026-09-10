use super::shell::ClientShellEndpointError;
use crate::api::schema::{ErrorBody, ResponseResult};

#[derive(serde::Deserialize)]
struct Envelope {
    id: String,
    result: Option<ResponseResult>,
    error: Option<ErrorBody>,
}

pub(crate) fn parse_response(
    expected_id: &str,
    response: &[u8],
) -> Result<ResponseResult, ClientShellEndpointError> {
    let envelope: Envelope =
        serde_json::from_slice(response).map_err(|error| ClientShellEndpointError {
            code: None,
            message: format!("invalid endpoint response: {error}"),
        })?;
    if envelope.id != expected_id {
        return Err(ClientShellEndpointError {
            code: None,
            message: "endpoint response id did not match request".into(),
        });
    }
    match (envelope.result, envelope.error) {
        (Some(result), None) => Ok(result),
        (None, Some(error)) => Err(ClientShellEndpointError {
            code: Some(error.code),
            message: error.message,
        }),
        (Some(_), Some(_)) | (None, None) => Err(ClientShellEndpointError {
            code: None,
            message: "endpoint response must contain exactly one result or error".into(),
        }),
    }
}
