// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (1284:1449). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use super::*;
use serde::{Deserialize, Serialize};
/// Notification kind forwarded from server to client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum NotifyKind {
    /// Play a sound (bell/agent-done, etc.).
    Sound,
    /// Display a toast message through the outer terminal.
    Toast,
    /// Display a toast message through the host OS notification service.
    SystemToast,
}

/// A client-rendered notification category. The server reports the semantic
/// event; each connected shell client chooses how (or whether) to present it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SemanticNotificationKind {
    NeedsAttention,
    Finished,
    UpdateInstalled,
    Custom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SemanticNotificationSound {
    Done,
    Request,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SemanticNotification {
    pub kind: SemanticNotificationKind,
    pub title: String,
    pub body: Option<String>,
    pub sound: Option<SemanticNotificationSound>,
    pub agent: Option<String>,
    pub workspace_id: Option<String>,
    pub tab_id: Option<String>,
    pub pane_id: Option<String>,
    pub position: Option<crate::ToastHerdrPosition>,
}

/// Messages sent from the server to the client over the client protocol socket.
///
/// Variant order is frozen for endpoint generation 1. Add compatible endpoint
/// behavior through `EndpointControl`, and ignore unrecognized named controls.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServerMessage {
    /// Handshake response: server acknowledges (or rejects) the client.
    Welcome {
        /// Protocol version the server speaks.
        version: u32,
        /// Render encoding selected by the server for this connection.
        encoding: RenderEncoding,
        /// If present, the handshake failed and this describes why.
        /// The client should exit with a clear error message.
        error: Option<String>,
    },

    /// Terminal bytes to write directly for a terminal-ANSI client.
    Terminal(TerminalFrame),

    /// Client-local Kitty graphics bytes to write directly to the host terminal.
    Graphics {
        /// Raw Kitty graphics protocol bytes.
        bytes: Vec<u8>,
    },

    /// Server is shutting down. Clients should exit gracefully.
    ServerShutdown {
        /// Optional reason for the shutdown.
        reason: Option<String>,
    },

    /// A notification event (sound/toast) to be rendered locally by the client.
    Notify {
        /// What kind of notification.
        kind: NotifyKind,
        /// Human-readable title or sound label.
        message: String,
        /// Optional human-readable notification body.
        body: Option<String>,
    },

    /// OSC 52 clipboard data forwarded from a PTY through the server.
    Clipboard {
        /// Base64-encoded clipboard data.
        data: String,
    },

    /// Set the foreground client's outer terminal window title.
    WindowTitle {
        /// Sanitized title to write with OSC 0. `None` restores Herdr's default title.
        title: Option<String>,
    },

    /// Client-local runtime config changed on disk; refresh it without reconnecting.
    ReloadSoundConfig,

    /// Whether the client should currently capture host mouse input.
    MouseCapture {
        /// True when Herdr mouse UI is enabled or the focused pane app requests mouse reporting.
        enabled: bool,
        /// True only while the focused pane requests DEC SGR pixel mode 1016.
        sgr_pixels: bool,
    },

    /// Ring the foreground client's outer terminal for pane-originated BEL characters.
    TerminalBell {
        /// Number of BEL characters parsed from one PTY read.
        count: u16,
    },

    /// One validated Herdr-owned Kitty regular-file RGBA transmission.
    GraphicsFile {
        path: String,
        expected_len: u64,
        image_id: u32,
        transfer_id: u64,
        leading: Vec<u8>,
        control: String,
        /// ClientShell upload identity. `None` targets a direct terminal client.
        surface_asset: Option<SurfaceGraphicsAssetKey>,
    },

    /// Suppress a direct command that expired before terminal delivery.
    GraphicsTransmissionRetired { transfer_id: u64, image_id: u32 },

    /// Initial metadata for a client-owned shell.
    ClientShellSnapshot(Box<ClientShellSnapshot>),

    /// Active-tab pane content rendered at a client-requested origin-relative size.
    PaneSurface(PaneSurfaceFrame),

    /// Ephemeral semantic notification delivered over the private control lane.
    /// It is sent only to currently connected client-rendered shells.
    SemanticNotification(SemanticNotification),

    /// Immediate endpoint error that the client-rendered shell must show regardless of notification policy.
    ClientShellError { message: String },

    /// Exact Kitty keyboard flags requested by a directly attached terminal.
    /// Zero restores the host terminal's previous keyboard mode.
    DirectTerminalKeyboardProtocol {
        flags: u16,
        modify_other_keys_level: u8,
    },

    /// Whether the focused pane or popup needs the shell host to report every key.
    ClientShellKeyboardReportAll { enabled: bool },

    /// One ordered chunk of the final response to an endpoint operation.
    ClientShellEndpointResponseChunk {
        boot_id: String,
        request_id: String,
        final_chunk: bool,
        data: Vec<u8>,
    },

    /// Incremental terminal-cell update for a previously committed pane surface.
    PaneSurfacePatch(PaneSurfacePatch),

    /// Extensible named control message for the stable client-owned endpoint protocol.
    ///
    /// This variant is append-only. Its bincode tag and two-string payload are part
    /// of endpoint generation 1 and must not change.
    EndpointControl { kind: String, data: String },
}
