use super::shell::ClientShellEndpointError;
use crate::api::schema::{ErrorResponse, ResponseResult, SuccessResponse};

#[derive(serde::Deserialize)]
#[serde(untagged)]
enum Envelope {
    Success(SuccessResponse),
    Error(ErrorResponse),
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
    match envelope {
        Envelope::Success(response) if response.id == expected_id => Ok(response.result),
        Envelope::Error(response) if response.id == expected_id => Err(ClientShellEndpointError {
            code: Some(response.error.code),
            message: response.error.message,
        }),
        Envelope::Success(_) | Envelope::Error(_) => Err(ClientShellEndpointError {
            code: None,
            message: "endpoint response id did not match request".into(),
        }),
    }
}
