import BicTermCore
import SwiftUI

struct ConnectionListView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(ConnectionsModel.self) private var model
    @Environment(KeyStore.self) private var keyStore
    @Environment(KeyAvailabilityPreferences.self) private var preferences
    @State private var herds = HerdsModel()
    @State private var editorTarget: EditorTarget?
    @State private var herdEditorTarget: HerdEditorTarget?
    @State private var forgetTarget: Connection?
    @State private var deleteTarget: Connection?
    let onConnectRequested: (Connection) -> Void
    var onOpenSessions: (() -> Void)?
    var onClose: (() -> Void)?
    var onForgetHost: ((Connection) -> Void)?
    /// Shared font-size preference handed to the Settings screen (the
    /// Appearance row shows its live value; the detail screen edits it).
    let fontModel: TerminalFontModel
    /// Shared appearance preference handed to the Settings screen (the
    /// Theme row shows its live value; the detail screen edits it).
    let themeModel: ThemeModel
    /// Shared OSC 52 clipboard-write toggle handed to the Settings screen.
    let osc52Model: Osc52ClipboardModel
    /// Shared keep-screen-on toggle handed to the Settings screen.
    let keepAwakeModel: KeepAwakeModel
    var onOpenHerd: ((Herd) -> Void)?

    init(
        fontModel: TerminalFontModel,
        themeModel: ThemeModel,
        osc52Model: Osc52ClipboardModel,
        keepAwakeModel: KeepAwakeModel,
        onConnectRequested: @escaping (Connection) -> Void = { _ in },
        onOpenSessions: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onForgetHost: ((Connection) -> Void)? = nil,
        onOpenHerd: ((Herd) -> Void)? = nil
    ) {
        self.fontModel = fontModel
        self.themeModel = themeModel
        self.osc52Model = osc52Model
        self.keepAwakeModel = keepAwakeModel
        self.onConnectRequested = onConnectRequested
        self.onOpenSessions = onOpenSessions
        self.onClose = onClose
        self.onForgetHost = onForgetHost
        self.onOpenHerd = onOpenHerd
    }

    struct EditorTarget: Identifiable {
        let connection: Connection?
        /// Duplicate-as-new pre-fill source: when set (with `connection`
        /// nil), the editor opens pre-filled from this connection as an add
        /// flow — nothing persists unless the user saves.
        let seed: Connection?

        init(connection: Connection?, seed: Connection? = nil) {
            self.connection = connection
            self.seed = seed
        }

        var id: String {
            if let connection { return connection.id.uuidString }
            if let seed { return "duplicate-\(seed.id.uuidString)" }
            return "new"
        }
    }

    struct HerdEditorTarget: Identifiable {
        let herd: Herd?
        var id: String { herd?.id.uuidString ?? "new" }
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
                    if let onOpenSessions {
                        Button(action: onOpenSessions) {
                            Image(systemName: "rectangle.on.rectangle")
                        }
                        .accessibilityLabel("Sessions")
                        .accessibilityIdentifier("open-sessions")
                        .foregroundColor(colors.accent)
                    }
                }
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
                    if let onClose {
                        Button("Done") { onClose() }
                            .accessibilityIdentifier("list-done")
                            .foregroundColor(colors.accent)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: SettingsView(fontModel: fontModel, themeModel: themeModel, osc52Model: osc52Model, keepAwakeModel: keepAwakeModel)) {
                        Image(systemName: "gear")
                            .foregroundColor(colors.accent)
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("open-settings")
                }
            }
            .sheet(item: $editorTarget) { target in
                ConnectionEditorView(existing: target.connection, seed: target.seed, model: model) { connection in
                    connect(connection)
                }
                .presentationDetents([.large])
            }
            .sheet(item: $herdEditorTarget) { target in
                HerdEditorView(existing: target.herd, model: herds)
                    .presentationDetents([.large])
            }
            .confirmationDialog(
                "Delete “\(deleteTarget?.name ?? "")”?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Connection", role: .destructive) {
                    if let target = deleteTarget {
                        Task { await model.delete(target) }
                    }
                    deleteTarget = nil
                }
                .accessibilityIdentifier("confirm-delete-connection")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteConfirmationMessage)
            }
            .confirmationDialog(
                "Forget host data for “\(forgetTarget?.name ?? "")”?",
                isPresented: Binding(
                    get: { forgetTarget != nil },
                    set: { if !$0 { forgetTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Forget Host Data", role: .destructive) {
                    if let target = forgetTarget {
                        onForgetHost?(target)
                    }
                    forgetTarget = nil
                }
                .accessibilityIdentifier("confirm-forget-host")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes the saved host key (destination and jump hops), stored passwords for this connection, restorable sessions, and herdr settings for this host. The connection entry itself is kept; nothing on the remote host is changed."
                )
            }
            .task {
                await herds.bootstrap()
                presentDebugEditorIfNeeded()
            }
            .onChange(of: model.connections) { _, _ in
                Task { await herds.reload() }
            }
        }
    }

    private var deleteConfirmationMessage: String {
        var message = "This removes the connection and its stored passwords. Sessions using it are not affected on the remote host."
        let referencing = deleteTarget.map { herds.herdsReferencing(connectionID: $0.id) } ?? []
        if !referencing.isEmpty {
            let names = referencing.map(\.name).sorted().joined(separator: ", ")
            message += "\n\nAlso used by herd(s): \(names). Those machines stay in their herds but can no longer connect until re-added."
        }
        return message
    }

    private var connectionList: some View {
        List {
            herdsSection
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
                            isAvailable: group.isAvailable
                        )
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { group.connections[$0] }
                        guard let first = doomed.first else { return }
                        deleteTarget = first
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

    private var herdsSection: some View {
        Section {
            ForEach(herds.herds) { herd in
                herdRow(herd)
            }
            .onDelete { offsets in
                let doomed = offsets.map { herds.herds[$0] }
                Task {
                    for herd in doomed { await herds.delete(herd) }
                }
            }

            Button {
                herdEditorTarget = HerdEditorTarget(herd: nil)
            } label: {
                Label("New Herd", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("add-herd")
            .foregroundColor(colors.accent)
        } header: {
            Text("Herds")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
        }
    }

    private func herdRow(_ herd: Herd) -> some View {
        Button {
            onOpenHerd?(herd)
        } label: {
            HStack(spacing: spacing.sm) {
                VStack(alignment: .leading, spacing: spacing.xxxs) {
                    Text(herd.name)
                        .font(typography.headline)
                        .foregroundColor(colors.foreground)
                    Text(herds.statusSummary(for: herd))
                        .font(typography.caption)
                        .foregroundColor(
                            herd.machines.contains { herds.connection(id: $0.connectionID) == nil }
                                ? colors.error
                                : colors.dimmed
                        )
                }
                Spacer()
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(colors.dimmed)
            }
            .padding(.vertical, spacing.xxs)
        }
        .accessibilityIdentifier("herd-\(sanitized(herd.name))")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await herds.delete(herd) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-herd-\(sanitized(herd.name))")

            Button {
                herdEditorTarget = HerdEditorTarget(herd: herd)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(colors.accent)
            .accessibilityIdentifier("edit-herd-\(sanitized(herd.name))")
        }
    }

    private func row(
        for connection: Connection,
        isAvailable: Bool
    ) -> some View {
        Button {
            connect(connection)
        } label: {
            rowLabel(for: connection, isAvailable: isAvailable)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection-\(sanitized(connection.name))")
        .accessibilityHint("Long press or secondary click for connection actions")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            rowActions(for: connection, isAvailable: isAvailable)
        }
        .contextMenu {
            rowActions(for: connection, isAvailable: isAvailable)
        }
    }

    /// The row's secondary actions, shared verbatim by the trailing swipe
    /// actions (touch) and the native context menu (pointer secondary click /
    /// touch long press), so both paths expose identical closures, labels,
    /// roles, and identifiers. The context menu is an additional access
    /// path — the swipe actions stay.
    @ViewBuilder
    private func rowActions(for connection: Connection, isAvailable: Bool) -> some View {
        Button(role: .destructive) {
            deleteTarget = connection
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier("delete-\(sanitized(connection.name))")

        Button {
            editorTarget = EditorTarget(connection: nil, seed: connection)
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

        Button {
            forgetTarget = connection
        } label: {
            Label("Forget Host", systemImage: "eraser")
        }
        .tint(colors.dimmed)
        .accessibilityIdentifier("forget-host-\(sanitized(connection.name))")

        Button {
            connect(connection)
        } label: {
            Label("Connect", systemImage: "play.fill")
        }
        .tint(colors.success)
        .disabled(!isAvailable)
        .accessibilityIdentifier("connect-\(sanitized(connection.name))")
    }

    private func rowLabel(
        for connection: Connection,
        isAvailable: Bool
    ) -> some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(connection.name)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)

                Text("\(connection.username)@\(connection.host):\(connection.port)")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                if connection.type == .ssh {
                    TerminalBadge(
                        authSummary(for: connection),
                        tint: colors.dimmed
                    )
                    .accessibilityIdentifier("auth-method-\(sanitized(connection.name))")
                }
            }

            Spacer()

            if !connection.jumpChain.isEmpty {
                TerminalBadge(
                    "\(connection.jumpChain.count) hops",
                    tint: colors.accent,
                    fill: colors.selection.opacity(0.5)
                )
                .accessibilityIdentifier("hopcount-\(sanitized(connection.name))")
            }

            VStack(alignment: .trailing, spacing: spacing.xxxs) {
                if connection.herdrEnabled {
                    TerminalBadge(
                        "Herdr",
                        tint: colors.accent,
                        stroke: colors.accent.opacity(0.5),
                        strokeWidth: 0.5
                    )
                    .accessibilityIdentifier("badge-herdr")
                }

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

    /// Resolver-computed row summary. Probe-free (no Keychain reads at
    /// render); the shared observable store/preference keep the count live
    /// across windows without dismissal hooks.
    private func authSummary(for connection: Connection) -> String {
        guard connection.offersKeys else { return "Password" }
        let offered = KeyOfferResolver().resolve(
            KeyOfferRequest(
                offersKeys: true,
                customKeys: connection.customKeys,
                hardwareKeysEnabledByDefault: preferences.hardwareOfferedByDefault
            ),
            keys: keyStore.keys.map(\.metadata)
        ).count
        return connection.customKeys == nil ? "All keys (\(offered) offered)" : "\(offered) selected keys"
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(typography.caption)
            .foregroundColor(colors.error)
            .frame(maxWidth: .infinity)
            .padding(spacing.xs)
            .background(colors.error.opacity(TerminalMetric.badgeFill))
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

    let protocolID: String

    var body: some View {
        TerminalBadge(
            protocolID,
            tint: colors.accent,
            stroke: colors.accent.opacity(0.5),
            strokeWidth: 0.5
        )
        .accessibilityIdentifier("badge-\(protocolID)")
    }
}
