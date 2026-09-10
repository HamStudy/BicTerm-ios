import Foundation

/// Immutable projection of the stable `shell.snapshot.v1` carrier decoded by
/// the Rust core. This is render-side data, not a wire-protocol mirror: the
/// frozen bincode codec never leaves Rust (integration doc §3.4).
public struct HerdrShellSnapshot: Sendable, Equatable, Decodable {
    public let bootID: String
    public let revision: UInt64
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [HerdrWorkspace]
    public let tabs: [HerdrTab]
    public let panes: [HerdrPane]
    public let configDiagnostic: String?
    public let productAnnouncement: HerdrAnnouncement?
    public let updateAvailable: String?

    enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case revision
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces, tabs, panes
        case configDiagnostic = "config_diagnostic"
        case productAnnouncement = "product_announcement"
        case updateAvailable = "update_available"
    }
}

/// Title-level view of an endpoint announcement (informational chrome only —
/// the install/update machinery stays on the host, integration doc §11).
public struct HerdrAnnouncement: Sendable, Equatable, Decodable {
    public let title: String
}

public struct HerdrWorkspace: Sendable, Equatable, Decodable {
    public let workspaceID: String
    public let activeTabID: String
    public let number: Int
    public let label: String
    public let focused: Bool

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case activeTabID = "active_tab_id"
        case number, label, focused
    }
}

public struct HerdrTab: Sendable, Equatable, Decodable {
    public let tabID: String
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let zoomed: Bool
    public let focused: Bool

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number, label, zoomed, focused
    }
}

public struct HerdrPane: Sendable, Equatable, Decodable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let label: String?
    public let cwd: String?
    public let focused: Bool
    public let rightClickPassthrough: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case label, cwd, focused
        case rightClickPassthrough = "right_click_passthrough"
    }
}
