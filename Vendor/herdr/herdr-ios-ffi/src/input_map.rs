//! Semantic-input translation: C key/text payloads to frozen wire events,
//! routed through the client core's qualified-pane guard.
use crate::client::{HerdrClient, Phase};
use crate::{
    herdr_key, FfiError, HERDR_CODE_CLIENT_FAILED, HERDR_CODE_INPUT_FROZEN,
    HERDR_CODE_INPUT_STALE_TARGET, HERDR_CODE_INPUT_WRITE_FAILED, HERDR_CODE_INVALID_ARGUMENT,
    HERDR_CODE_NOT_ONLINE, HERDR_KEY_BACKSPACE, HERDR_KEY_BACK_TAB, HERDR_KEY_CHAR,
    HERDR_KEY_DELETE, HERDR_KEY_DOWN, HERDR_KEY_END, HERDR_KEY_ENTER, HERDR_KEY_ESC,
    HERDR_KEY_FUNCTION, HERDR_KEY_HOME, HERDR_KEY_INSERT, HERDR_KEY_KIND_PRESS,
    HERDR_KEY_KIND_RELEASE, HERDR_KEY_KIND_REPEAT, HERDR_KEY_LEFT, HERDR_KEY_NULL,
    HERDR_KEY_PAGE_DOWN, HERDR_KEY_PAGE_UP, HERDR_KEY_RIGHT, HERDR_KEY_TAB, HERDR_KEY_UP,
};
use herdr_client_core::client::shell::{InputError, PaneInput, QualifiedPane};
use herdr_protocol::{ClientKeyCode, ClientKeyKind, ClientPaneInputEvent};

pub(crate) enum InputPayload {
    TextCommit(String),
    Key { key: herdr_key },
    Paste(String),
}

impl HerdrClient {
    pub(crate) fn send_input(
        &mut self,
        pane_id: &str,
        input: InputPayload,
    ) -> Result<(), FfiError> {
        if matches!(self.phase, Phase::AwaitingWelcome { .. }) {
            return Err(FfiError::new(
                HERDR_CODE_NOT_ONLINE,
                "input requires a completed endpoint handshake",
            ));
        }
        if matches!(self.phase, Phase::Failed) {
            return Err(FfiError::new(
                HERDR_CODE_CLIENT_FAILED,
                "client already failed a protocol check; destroy and reconnect",
            ));
        }
        let event = match input {
            InputPayload::TextCommit(text) => ClientPaneInputEvent::TextCommit(text),
            InputPayload::Paste(text) => ClientPaneInputEvent::Paste(text),
            InputPayload::Key { key } => ClientPaneInputEvent::Key {
                code: key_code(&key)?,
                modifiers: key.modifiers,
                kind: key_kind(key.kind)?,
                repeat_count: key.repeat_count,
                shifted_codepoint: scalar(key.shifted_codepoint)?.map(u32::from),
                generated_text: None,
                tracks_release: true,
                physical_key_id: None,
                windows_record: None,
            },
        };
        let boot_id = match self.shell.endpoint_snapshot(&self.endpoint) {
            Some(snapshot) => snapshot.boot_id.clone(),
            None => {
                return Err(FfiError::new(
                    HERDR_CODE_INPUT_FROZEN,
                    "no authoritative snapshot yet; pane input stays frozen",
                ))
            }
        };
        let input = PaneInput {
            target: QualifiedPane {
                endpoint: self.endpoint.clone(),
                generation: self.generation,
                boot_id,
                pane_id: pane_id.to_owned(),
            },
            event,
        };
        match self.shell.send_pane_input(&mut self.registry, input) {
            Ok(()) => Ok(()),
            Err(InputError::Frozen) => Err(FfiError::new(
                HERDR_CODE_INPUT_FROZEN,
                "input is frozen until surface activation completes",
            )),
            Err(InputError::StaleTarget) => Err(FfiError::new(
                HERDR_CODE_INPUT_STALE_TARGET,
                "pane target does not match the active endpoint lease",
            )),
            Err(InputError::WriteFailed) => Err(FfiError::new(
                HERDR_CODE_INPUT_WRITE_FAILED,
                "outbound queue rejected the input frame",
            )),
        }
    }
}

fn key_code(key: &herdr_key) -> Result<ClientKeyCode, FfiError> {
    let code = match key.code {
        HERDR_KEY_BACKSPACE => ClientKeyCode::Backspace,
        HERDR_KEY_ENTER => ClientKeyCode::Enter,
        HERDR_KEY_LEFT => ClientKeyCode::Left,
        HERDR_KEY_RIGHT => ClientKeyCode::Right,
        HERDR_KEY_UP => ClientKeyCode::Up,
        HERDR_KEY_DOWN => ClientKeyCode::Down,
        HERDR_KEY_HOME => ClientKeyCode::Home,
        HERDR_KEY_END => ClientKeyCode::End,
        HERDR_KEY_PAGE_UP => ClientKeyCode::PageUp,
        HERDR_KEY_PAGE_DOWN => ClientKeyCode::PageDown,
        HERDR_KEY_TAB => ClientKeyCode::Tab,
        HERDR_KEY_BACK_TAB => ClientKeyCode::BackTab,
        HERDR_KEY_DELETE => ClientKeyCode::Delete,
        HERDR_KEY_INSERT => ClientKeyCode::Insert,
        HERDR_KEY_ESC => ClientKeyCode::Esc,
        HERDR_KEY_NULL => ClientKeyCode::Null,
        HERDR_KEY_CHAR => ClientKeyCode::Char(scalar(key.codepoint)?.ok_or_else(|| {
            FfiError::new(
                HERDR_CODE_INVALID_ARGUMENT,
                "HERDR_KEY_CHAR needs a codepoint",
            )
        })?),
        HERDR_KEY_FUNCTION => {
            let number = key.codepoint;
            if !(1..=35).contains(&number) {
                return Err(FfiError::new(
                    HERDR_CODE_INVALID_ARGUMENT,
                    "function key number must be 1..=35",
                ));
            }
            ClientKeyCode::F(number as u8)
        }
        other => {
            return Err(FfiError::new(
                HERDR_CODE_INVALID_ARGUMENT,
                format!("unknown HERDR_KEY code {other}"),
            ))
        }
    };
    Ok(code)
}

fn key_kind(kind: u8) -> Result<ClientKeyKind, FfiError> {
    match kind {
        HERDR_KEY_KIND_PRESS => Ok(ClientKeyKind::Press),
        HERDR_KEY_KIND_REPEAT => Ok(ClientKeyKind::Repeat),
        HERDR_KEY_KIND_RELEASE => Ok(ClientKeyKind::Release),
        other => Err(FfiError::new(
            HERDR_CODE_INVALID_ARGUMENT,
            format!("unknown key kind {other}"),
        )),
    }
}

/// Maps 0 to `None` and any other value through `char::from_u32` validation.
fn scalar(value: u32) -> Result<Option<char>, FfiError> {
    if value == 0 {
        return Ok(None);
    }
    char::from_u32(value).map(Some).ok_or_else(|| {
        FfiError::new(
            HERDR_CODE_INVALID_ARGUMENT,
            format!("codepoint {value:#x} is not a unicode scalar"),
        )
    })
}
