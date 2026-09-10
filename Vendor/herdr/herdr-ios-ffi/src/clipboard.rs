//! Clipboard plumbing: OSC 52 server clipboard intake (base64-decoded,
//! capped, one-shot slot) and the local-to-remote image paste bridge.
use crate::client::{HerdrClient, Phase};
use crate::{
    FfiError, HERDR_CODE_CLIENT_FAILED, HERDR_CODE_CLIPBOARD_DROPPED, HERDR_CODE_INPUT_FROZEN,
    HERDR_CODE_INPUT_WRITE_FAILED, HERDR_CODE_INVALID_ARGUMENT, HERDR_CODE_NOT_ONLINE,
};
use base64::Engine as _;
use herdr_client_core::EndpointTransport;
use herdr_protocol::{ClientClipboardImageTarget, ClientMessage, MAX_CLIPBOARD_IMAGE_PAYLOAD};

impl HerdrClient {
    /// Accepts one OSC 52 clipboard frame: rejects payloads whose decoded
    /// size would exceed the protocol clipboard cap before allocating,
    /// stores everything else in the one-shot slot for
    /// `herdr_client_take_clipboard`. A drop is non-fatal; the receive call
    /// surfaces the structured detail and the client stays Online.
    pub(crate) fn accept_clipboard(&mut self, data: &str) -> Result<(), FfiError> {
        let dropped = |detail: String| FfiError::new(HERDR_CODE_CLIPBOARD_DROPPED, detail);
        if data.len().div_ceil(4) * 3 > MAX_CLIPBOARD_IMAGE_PAYLOAD {
            return Err(dropped(format!(
                "clipboard payload exceeds the {MAX_CLIPBOARD_IMAGE_PAYLOAD}-byte protocol cap"
            )));
        }
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|error| dropped(format!("clipboard payload is not valid base64: {error}")))?;
        self.pending_clipboard = Some(decoded);
        Ok(())
    }

    /// Drains the one-shot clipboard slot; `None` means no clipboard frame
    /// arrived since the previous take.
    pub(crate) fn take_clipboard(&mut self) -> Option<Vec<u8>> {
        self.pending_clipboard.take()
    }

    /// Queues one local-clipboard image for remote paste bridging, guarded
    /// exactly like semantic input: Online phase and an unfrozen lane.
    pub(crate) fn send_clipboard_image(
        &mut self,
        pane_id: &str,
        extension: &str,
        data: &[u8],
    ) -> Result<(), FfiError> {
        if matches!(self.phase, Phase::AwaitingWelcome { .. }) {
            return Err(FfiError::new(
                HERDR_CODE_NOT_ONLINE,
                "clipboard image requires a completed endpoint handshake",
            ));
        }
        if matches!(self.phase, Phase::Failed) {
            return Err(FfiError::new(
                HERDR_CODE_CLIENT_FAILED,
                "client already failed a protocol check; destroy and reconnect",
            ));
        }
        if !self.registry.active_surface_available() {
            return Err(FfiError::new(
                HERDR_CODE_INPUT_FROZEN,
                "input is frozen until surface activation completes",
            ));
        }
        if data.len() > MAX_CLIPBOARD_IMAGE_PAYLOAD {
            return Err(FfiError::new(
                HERDR_CODE_INVALID_ARGUMENT,
                format!(
                    "clipboard image exceeds the {MAX_CLIPBOARD_IMAGE_PAYLOAD}-byte protocol cap"
                ),
            ));
        }
        let message = ClientMessage::ClipboardImage {
            target: ClientClipboardImageTarget::Pane(pane_id.to_owned()),
            extension: extension.to_owned(),
            data: data.to_vec(),
        };
        self.queue
            .send(&message)
            .map_err(|error| FfiError::new(HERDR_CODE_INPUT_WRITE_FAILED, error.to_string()))
    }
}
