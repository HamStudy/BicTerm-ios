//! Client construction: config validation and the conservative
//! generation-1 endpoint hello (doc §4).
use crate::client::{HerdrClient, Phase};
use crate::errors::handshake_error;
use crate::{herdr_client_config, FfiError, HERDR_CODE_PROTOCOL_VIOLATION};
use herdr_client_core::handshake::PendingHandshake;
use herdr_client_core::outbound::{OutboundQueue, QueueLimits};
use herdr_client_core::{
    ClientEndpointId, ClientShellState, EndpointRegistry, EndpointTransport, ProfileId,
};
use herdr_protocol::endpoint::{
    EndpointClientHello, BLOB_CODEC_V1, ENDPOINT_PROTOCOL_GENERATION, INPUT_CODEC_V1,
    SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
};
use herdr_protocol::{ClientSurfaceSize, MAX_FRAME_SIZE, MAX_GRAPHICS_FRAME_SIZE};
use std::time::Instant;

const DEFAULT_OUTBOUND_MESSAGES: usize = 256;
const DEFAULT_OUTBOUND_BYTES: usize = 4 * 1024 * 1024;

pub(crate) fn create(config: &herdr_client_config) -> Result<HerdrClient, FfiError> {
    let invalid = |detail: &str| FfiError::new(crate::HERDR_CODE_INVALID_ARGUMENT, detail);
    if config.cols == 0 || config.cols > u16::MAX as u32 {
        return Err(invalid("config.cols must be 1..=65535"));
    }
    if config.rows == 0 || config.rows > u16::MAX as u32 {
        return Err(invalid("config.rows must be 1..=65535"));
    }
    let max_frame_size = match config.max_frame_size {
        0 => MAX_FRAME_SIZE,
        size if size as usize <= MAX_GRAPHICS_FRAME_SIZE => size as usize,
        _ => {
            return Err(invalid(
                "config.max_frame_size exceeds the protocol ceiling",
            ))
        }
    };
    let limits = QueueLimits {
        messages: match config.outbound_message_limit {
            0 => DEFAULT_OUTBOUND_MESSAGES,
            limit => limit as usize,
        },
        bytes: match config.outbound_byte_limit {
            0 => DEFAULT_OUTBOUND_BYTES,
            limit => limit as usize,
        },
    };
    // Conservative generation-1 hello (doc §4): declared codecs only,
    // direct_graphics off; pixel/mouse flags are caller policy.
    let hello = EndpointClientHello {
        generation: ENDPOINT_PROTOCOL_GENERATION,
        cell_width_px: config.cell_width_px,
        cell_height_px: config.cell_height_px,
        surface_size: ClientSurfaceSize {
            cols: config.cols as u16,
            rows: config.rows as u16,
        },
        pixel_mouse: config.pixel_mouse,
        direct_graphics: false,
        endpoint_keybindings: false,
        mouse_capture: config.mouse_capture,
        surface_active: true,
        snapshot_codecs: vec![SNAPSHOT_CODEC_V1.to_owned()],
        surface_codecs: vec![SURFACE_CODEC_V1.to_owned()],
        input_codecs: vec![INPUT_CODEC_V1.to_owned()],
        blob_codecs: vec![BLOB_CODEC_V1.to_owned()],
    };
    let (handshake, hello_message) =
        PendingHandshake::begin(&hello, Instant::now()).map_err(handshake_error)?;
    let mut queue = OutboundQueue::new(limits);
    queue
        .send(&hello_message)
        .map_err(|error| FfiError::new(HERDR_CODE_PROTOCOL_VIOLATION, error.to_string()))?;
    Ok(HerdrClient {
        endpoint: ClientEndpointId::Ssh(ProfileId::generate()),
        generation: 1,
        inbound: Vec::new(),
        phase: Phase::AwaitingWelcome(Box::new(handshake)),
        queue,
        registry: EndpointRegistry::empty(),
        shell: ClientShellState::new(),
        max_frame_size,
        snapshot: None,
        pending: None,
        pending_clipboard: None,
        cols: config.cols as u16,
        rows: config.rows as u16,
        cell_width_px: config.cell_width_px,
        cell_height_px: config.cell_height_px,
        pixel_mouse: config.pixel_mouse,
        activation_serial: 0,
        last_detail: std::ffi::CString::new("").expect("static"),
    })
}
