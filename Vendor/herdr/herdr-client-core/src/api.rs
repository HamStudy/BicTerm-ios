//! JSON projections of the upstream activation methods, not a replacement wire codec.
pub mod schema {
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct Request {
        pub id: String,
        #[serde(flatten)]
        pub method: Method,
    }

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    #[serde(tag = "method", content = "params")]
    pub enum Method {
        #[serde(rename = "client_shell.surface.set")]
        ClientShellSurfaceSet(ClientShellSurfaceSetParams),
        #[serde(rename = "workspace.focus")]
        WorkspaceFocus(WorkspaceTarget),
        #[serde(rename = "tab.focus")]
        TabFocus(TabTarget),
        #[serde(rename = "pane.focus")]
        PaneFocus(PaneTarget),
    }

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct ClientShellSurfaceSetParams {
        pub active: bool,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct WorkspaceTarget {
        pub workspace_id: String,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct TabTarget {
        pub tab_id: String,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct PaneTarget {
        pub pane_id: String,
    }

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct WorkspaceInfo {
        pub workspace_id: String,
        pub focused: bool,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct TabInfo {
        pub tab_id: String,
        pub focused: bool,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct PaneInfo {
        pub pane_id: String,
        pub focused: bool,
    }

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    #[serde(tag = "type", rename_all = "snake_case")]
    pub enum ResponseResult {
        ClientShellSurfaceSet {
            active: bool,
            projection_revision: u64,
        },
        WorkspaceInfo {
            workspace: WorkspaceInfo,
        },
        TabInfo {
            tab: TabInfo,
        },
        PaneInfo {
            pane: PaneInfo,
        },
    }

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    pub struct SuccessResponse {
        pub id: String,
        pub result: ResponseResult,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    pub struct ErrorResponse {
        pub id: String,
        pub error: ErrorBody,
    }
    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    pub struct ErrorBody {
        pub code: String,
        pub message: String,
    }
}
