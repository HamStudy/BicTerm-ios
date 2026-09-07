import BicTermCore
import SwiftUI

struct ConnectionListView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @State private var model = ConnectionsModel()
    @State private var editorTarget: EditorTarget?
    let onConnectRequested: (Connection) -> Void

    init(onConnectRequested: @escaping (Connection) -> Void = { _ in }) {
        self.onConnectRequested = onConnectRequested
    }

    struct EditorTarget: Identifiable {
        let connection: Connection?
        var id: String { connection?.id.uuidString ?? "new" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError = model.loadError {
                    errorBanner(loadError)
                }
                connectionList
            }
            .navigationTitle("BicTerm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorTarget = EditorTarget(connection: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Connection")
                    .accessibilityIdentifier("add-connection")
                    .foregroundColor(colors.accent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(colors.accent)
                    }
                    .accessibilityIdentifier("open-settings")
                }
            }
            .sheet(item: $editorTarget) { target in
                ConnectionEditorView(existing: target.connection, model: model) { connection in
                    connect(connection)
                }
                .presentationDetents([.large])
            }
            .task {
                await model.bootstrap()
                presentDebugEditorIfNeeded()
            }
            .onAppear {
                Task {
                    await model.refreshCoderStatuses()
                }
            }
        }
    }

    private var connectionList: some View {
        List {
            if model.connections.isEmpty && model.loadError == nil {
                Text("No connections yet. Tap + to add one.")
                    .font(typography.body)
                    .foregroundColor(colors.dimmed)
                    .listRowBackground(colors.background)
            }
            ForEach(model.groupedConnections) { group in
                Section {
                    ForEach(group.connections) { connection in
                        row(
                            for: connection,
                            isAvailable: group.isAvailable,
                            coderStatus: model.coderStatus(for: connection)
                        )
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { group.connections[$0] }
                        Task {
                            for connection in doomed { await model.delete(connection) }
                        }
                    }
                } header: {
                    Text(group.title)
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .accessibilityIdentifier("connectionList")
    }

    private func row(
        for connection: Connection,
        isAvailable: Bool,
        coderStatus: ConnectionsModel.CoderConnectionStatus?
    ) -> some View {
        Button {
            editorTarget = EditorTarget(connection: connection)
        } label: {
            rowLabel(for: connection, isAvailable: isAvailable, coderStatus: coderStatus)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection-\(sanitized(connection.name))")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.delete(connection) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-\(sanitized(connection.name))")

            Button {
                Task { await model.duplicate(connection) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(colors.selection)
            .accessibilityIdentifier("duplicate-\(sanitized(connection.name))")

            Button {
                editorTarget = EditorTarget(connection: connection)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(colors.accent)
            .accessibilityIdentifier("edit-\(sanitized(connection.name))")

            if let coderStatus, coderStatus.isUnauthorized, let serverID = coderStatus.serverID {
                Button {
                    NotificationCenter.default.post(
                        name: .coderReauthenticationRequested,
                        object: nil,
                        userInfo: ["serverID": serverID]
                    )
                } label: {
                    Label("Reauthenticate", systemImage: "key.fill")
                }
                .tint(colors.error)
                .accessibilityIdentifier("reauthenticate-\(sanitized(connection.name))")
            }

            Button {
                connect(connection)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .tint(colors.success)
            .disabled(!isAvailable)
            .accessibilityIdentifier("connect-\(sanitized(connection.name))")
        }
    }

    private func rowLabel(
        for connection: Connection,
        isAvailable: Bool,
        coderStatus: ConnectionsModel.CoderConnectionStatus?
    ) -> some View {
        HStack(spacing: spacing.sm) {
            Circle()
                .fill(coderStatus?.isConnectable == true ? colors.success : colors.dimmed)
                .frame(width: 8, height: 8)
                .accessibilityLabel(coderStatus?.isConnectable == true ? "Running" : "Idle")

            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(connection.name)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)

                if let coderStatus {
                    Text("\(coderStatus.workspaceName) · \(coderStatus.serverName)")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)

                    HStack(spacing: spacing.xxxs) {
                        if let state = coderStatus.state {
                            Text(state.rawValue.capitalized)
                                .font(typography.caption)
                                .foregroundColor(coderStatus.isConnectable ? colors.success : colors.error)
                        }
                        if coderStatus.isUnauthorized {
                            Text("Reauthenticate")
                                .font(typography.caption)
                                .foregroundColor(colors.error)
                        }
                    }
                } else {
                    Text("\(connection.username)@\(connection.host):\(connection.port)")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
            }

            Spacer()

            if !connection.jumpChain.isEmpty {
                Text("\(connection.jumpChain.count) hops")
                    .font(typography.caption)
                    .foregroundColor(colors.accent)
                    .padding(.horizontal, spacing.xs)
                    .padding(.vertical, spacing.xxxs)
                    .background(colors.selection.opacity(0.5), in: Capsule())
                    .accessibilityIdentifier("hopcount-\(sanitized(connection.name))")
            }

            VStack(alignment: .trailing, spacing: spacing.xxxs) {
                ProtocolBadge(protocolID: connection.type.rawValue)

                if !isAvailable {
                    Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(typography.caption)
                        .foregroundStyle(colors.error)
                        .accessibilityIdentifier("unavailable-\(sanitized(connection.name))")
                }
            }
        }
        .padding(.vertical, spacing.xxs)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(typography.caption)
            .foregroundColor(colors.error)
            .frame(maxWidth: .infinity)
            .padding(spacing.xs)
            .background(colors.error.opacity(0.15))
            .accessibilityIdentifier("connections-error")
    }

    private func connect(_ connection: Connection) {
        guard model.isProtocolAvailable(for: connection) else { return }
        onConnectRequested(connection)
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private func presentDebugEditorIfNeeded() {
        #if DEBUG
        guard let name = AppServices.shared.debugAutoOpenEditorForConnectionNamed else { return }
        AppServices.shared.debugAutoOpenEditorForConnectionNamed = nil
        if let connection = model.connections.first(where: { $0.name == name }) {
            editorTarget = EditorTarget(connection: connection)
        }
        #endif
    }
}

struct ProtocolBadge: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    let protocolID: String

    var body: some View {
        Text(protocolID)
            .font(typography.caption)
            .foregroundColor(colors.accent)
            .padding(.horizontal, spacing.xs)
            .padding(.vertical, spacing.xxxs)
            .background(colors.accent.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(colors.accent.opacity(0.5), lineWidth: 0.5))
            .accessibilityIdentifier("badge-\(protocolID)")
    }
}
