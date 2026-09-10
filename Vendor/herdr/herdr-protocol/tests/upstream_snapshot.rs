// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/protocol/wire.rs (2612:2693). Apache-2.0.
// Modified: desktop conversions excluded; shared data paths relocated.
use herdr_protocol::*;
#[test]
fn client_shell_snapshot_roundtrip() {
    let msg = ServerMessage::ClientShellSnapshot(Box::new(ClientShellSnapshot {
        boot_id: "boot-1".into(),
        revision: 1,
        config_diagnostic: Some("endpoint config warning".into()),
        product_announcement: Some(ClientShellProductAnnouncement {
            version: "0.8.2".into(),
            id: "client-shell".into(),
            title: "Client shell".into(),
            body: "### New\n- Client-owned chrome".into(),
            preview: false,
        }),
        update_available: Some("0.8.3".into()),
        update_install_command: "herdr update".into(),
        server_keybindings_toml: Some("[keys]\nprefix = \"ctrl+a\"\n".into()),
        latest_release_notes_available: true,
        integration_updates_available: true,
        worktree_directory: "/tmp/herdr-worktrees".into(),
        release_notes: Some(ClientShellReleaseNotes {
            version: "0.8.3".into(),
            body: "### New\n- Update ready".into(),
            preview: true,
        }),
        focused_workspace_id: Some("w1".into()),
        focused_tab_id: Some("w1:t1".into()),
        focused_pane_id: Some("w1:p1".into()),
        tab_bar_right: vec![ClientShellTabStatusSegment {
            text: "host".into(),
            accent: false,
        }],
        tab_bar_right_separator: " · ".into(),
        agent_view_label: None,
        agent_order: Vec::new(),
        workspaces: vec![ClientShellWorkspace {
            workspace_id: "w1".into(),
            active_tab_id: "w1:t1".into(),
            new_workspace_cwd: "/tmp".into(),
            number: 1,
            label: "shell".into(),
            custom_label: false,
            branch: Some("main".into()),
            git_ahead_behind: None,
            tokens: Vec::new(),
            worktree: None,
            focused: true,
            agent_status: crate::AgentStatus::Idle,
        }],
        tabs: vec![ClientShellTab {
            tab_id: "w1:t1".into(),
            workspace_id: "w1".into(),
            number: 1,
            label: "main".into(),
            custom_label: true,
            zoomed: false,
            focused: true,
            agent_status: crate::AgentStatus::Idle,
        }],
        panes: vec![ClientShellPane {
            pane_id: "w1:p1".into(),
            workspace_id: "w1".into(),
            tab_id: "w1:t1".into(),
            label: None,
            cwd: Some("/repo".into()),
            foreground_cwd: Some("/repo".into()),
            focused: true,
            right_click_passthrough: false,
        }],
        agents: Vec::new(),
        commands: vec![ClientShellCommand {
            command_id: "cmd_0123456789abcdef0123456789abcdef".into(),
            binding_label: "prefix+z".into(),
            binding_labels: vec!["prefix+z".into()],
            action: ClientShellCommandAction::Shell,
            description: Some("deploy".into()),
        }],
    }));
    let encoded = bincode::serde::encode_to_vec(&msg, bincode::config::standard()).unwrap();
    let (decoded, _): (ServerMessage, _) =
        bincode::serde::decode_from_slice(&encoded, bincode::config::standard()).unwrap();
    assert_eq!(msg, decoded);
}
