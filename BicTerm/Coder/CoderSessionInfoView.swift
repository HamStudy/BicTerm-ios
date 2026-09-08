import BicTermCore
import SwiftUI

/// App-side sink for Coder session diagnostics: network-path observations
/// derived from the Go core's `networkPathChanged` events (the
/// ``CoderNetEvent`` taxonomy) keyed by scene, plus cached per-server
/// buildinfo versions.
@MainActor
@Observable
final class CoderSessionDiagnostics {
    private(set) var networkPaths: [String: CoderNetPathKind] = [:]
    private(set) var serverVersions: [UUID: String] = [:]

    func networkPath(forScene sceneID: String) -> CoderNetPathKind? {
        networkPaths[sceneID]
    }

    func serverVersion(for serverID: UUID) -> String? {
        serverVersions[serverID]
    }

    func apply(_ event: CoderNetEvent, sceneID: String) {
        guard event.type == .networkPathChanged, let path = event.path else { return }
        networkPaths[sceneID] = path
    }

    func recordServerVersion(_ version: String, for serverID: UUID) {
        serverVersions[serverID] = version
    }
}

/// Connection diagnostics for an active Coder session: direct-vs-relayed
/// network path, workspace/agent identities, and the server's version.
struct CoderSessionInfoView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let connection: Connection
    let sceneID: String
    let diagnostics: CoderSessionDiagnostics

    @State private var serverVersion: String?
    @State private var seamApplied = false

    var body: some View {
        List {
            Section("Session") {
                infoRow(
                    label: "Network path",
                    value: pathText,
                    detail: "From the tunnel core's network-path events",
                    identifier: "coder-info-path"
                )
                infoRow(
                    label: "Server",
                    value: serverText,
                    detail: nil,
                    identifier: "coder-info-server"
                )
                infoRow(
                    label: "Workspace",
                    value: workspaceText,
                    detail: nil,
                    identifier: "coder-info-workspace"
                )
                infoRow(
                    label: "Agent",
                    value: agentText,
                    detail: nil,
                    identifier: "coder-info-agent"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Coder Session Info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var pathText: String {
        switch diagnostics.networkPath(forScene: sceneID) {
        case .direct: "Direct"
        case .relayed: "Relayed"
        case nil: "Unknown"
        }
    }

    private var serverText: String {
        let name = connection.protocolOptions["coder.serverName"]?.stringValue ?? "Unknown server"
        if let serverVersion {
            return "\(name) · \(serverVersion)"
        }
        return name
    }

    private var workspaceText: String {
        let name = connection.protocolOptions["coder.workspaceName"]?.stringValue ?? "Unknown workspace"
        guard let id = connection.coderRef?.workspaceID else {
            return name
        }
        return "\(name) · \(shortID(id))"
    }

    private var agentText: String {
        let name = connection.protocolOptions["coder.agentName"]?.stringValue
        let id = connection.protocolOptions["coder.agentID"]?.stringValue.flatMap(UUID.init(uuidString:))
        if let name, let id {
            return "\(name) · \(shortID(id))"
        }
        if let name {
            return name
        }
        return "Automatic (single agent)"
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func infoRow(
        label: String,
        value: String,
        detail: String?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing.xxxs) {
            Text(label)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Text(value)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier(identifier)
            if let detail {
                Text(detail)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
        }
        .padding(.vertical, spacing.xxxs)
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-coder-netpath-relayed"), !seamApplied {
            seamApplied = true
            diagnostics.apply(
                CoderNetEvent(type: .networkPathChanged, source: .coord, path: .relayed),
                sceneID: sceneID
            )
        }
        #endif

        guard let reference = connection.coderRef else { return }
        if let cached = diagnostics.serverVersion(for: reference.serverID) {
            serverVersion = cached
            return
        }
        guard let server = try? await AppServices.shared.coderServerStore.coderServer(id: reference.serverID) else { return }
        let fetched = await CoderWorkspaceStarter().fetchServerVersion(server: server)
        if let fetched {
            diagnostics.recordServerVersion(fetched, for: server.id)
            serverVersion = fetched
        }
    }
}

#Preview("Session Info") {
    CoderSessionInfoView(
        connection: try! Connection(
            name: "Dev",
            type: .coder,
            host: "coder.example.com",
            port: 443,
            username: "dev",
            keyReference: ""
        ),
        sceneID: "scene-preview",
        diagnostics: CoderSessionDiagnostics()
    )
    .terminalStyle()
}
