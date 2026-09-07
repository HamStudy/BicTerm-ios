import BicTermCore
import SwiftUI

struct CoderServersListView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    @State private var model: CoderServersModel
    @State private var editorTarget: EditorTarget?
    @State private var serverToDelete: CoderServer?
    @State private var serverToForceDelete: CoderServer?
    @State private var deleteError: String?

    init(model: CoderServersModel) {
        self._model = State(initialValue: model)
    }

    @State private var autoOpenServerID: UUID?

    struct EditorTarget: Identifiable, Hashable {
        let server: CoderServer?
        var id: String { server?.id.uuidString ?? "new" }

        static func == (lhs: EditorTarget, rhs: EditorTarget) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    var body: some View {
        Group {
            if let loadError = model.loadError {
                errorBanner(loadError)
            }
            serverList
        }
        .navigationTitle("Coder Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = EditorTarget(server: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("add-coder-server")
                .accessibilityLabel("Add Coder Server")
                .foregroundColor(colors.accent)
            }
        }
        .navigationDestination(item: $editorTarget) { target in
            CoderServerEditorView(
                model: model,
                existing: target.server
            ) { result in
                handleEditorResult(result)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coderOpenServerEditor)) { notification in
            if let serverID = notification.userInfo?["serverID"] as? UUID {
                autoOpenServerID = serverID
            }
        }
        .onChange(of: autoOpenServerID) { _, serverID in
            guard let serverID,
                  let server = model.servers.first(where: { $0.id == serverID })
            else { return }
            editorTarget = EditorTarget(server: server)
            autoOpenServerID = nil
        }
        .onChange(of: model.servers) { _, _ in
            guard let serverID = autoOpenServerID,
                  let server = model.servers.first(where: { $0.id == serverID })
            else { return }
            editorTarget = EditorTarget(server: server)
            autoOpenServerID = nil
        }
        .alert(
            "Delete Coder Server?",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            presenting: serverToDelete
        ) { server in
            Button("Cancel", role: .cancel) { serverToDelete = nil }
            Button("Delete", role: .destructive) {
                Task { await performDelete(server, force: false) }
            }
            .accessibilityIdentifier("confirm-delete-coder-server")
        } message: { server in
            Text("Remove \"\(server.name)\" and its saved token from this device?")
        }
        .alert(
            "Server Still in Use",
            isPresented: Binding(
                get: { serverToForceDelete != nil },
                set: { if !$0 { serverToForceDelete = nil } }
            ),
            presenting: serverToForceDelete
        ) { server in
            Button("Cancel", role: .cancel) { serverToForceDelete = nil }
            Button("Delete Anyway", role: .destructive) {
                Task { await performDelete(server, force: true) }
            }
            .accessibilityIdentifier("force-delete-coder-server")
        } message: { server in
            Text(deleteError ?? "\(server.name) is still used by saved connections.")
        }
        .task {
            #if DEBUG
            await AppServices.shared.startupResetTask?.value
            #endif
            await model.reload()
        }
    }

    private var serverList: some View {
        List {
            if model.servers.isEmpty && !model.isLoading {
                Text("No Coder servers configured.")
                    .font(typography.body)
                    .foregroundColor(colors.dimmed)
                    .listRowBackground(colors.background)
                    .accessibilityIdentifier("coder-servers-empty")
            }
            ForEach(model.servers) { server in
                Button {
                    editorTarget = EditorTarget(server: server)
                } label: {
                    CoderServerRow(server: server)
                }
                .buttonStyle(.plain)
                .listRowBackground(colors.background)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        serverToDelete = server
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("delete-coder-server-\(sanitized(server.name))")
                }
                .accessibilityIdentifier("coder-server-\(sanitized(server.name))")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .accessibilityIdentifier("coder-servers-list")
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(typography.caption)
            .foregroundColor(colors.error)
            .frame(maxWidth: .infinity)
            .padding(spacing.xs)
            .background(colors.error.opacity(0.15))
            .accessibilityIdentifier("coder-servers-error")
    }

    private func handleEditorResult(_ result: CoderServerEditorResult) {
        editorTarget = nil
        switch result {
        case .saved:
            break
        case .cancelled:
            break
        }
    }

    private func performDelete(_ server: CoderServer, force: Bool) async {
        deleteError = nil
        serverToDelete = nil
        serverToForceDelete = nil
        let result: Result<Void, CoderServerDeleteError>
        if force {
            result = await model.forceDelete(server)
        } else {
            result = await model.delete(server)
        }
        switch result {
        case .success:
            break
        case .failure(let error):
            switch error {
            case .referencedConnections:
                deleteError = error.localizedDescription
                serverToForceDelete = server
            default:
                model.loadError = error.localizedDescription
            }
        }
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}

enum CoderServerEditorResult {
    case saved
    case cancelled
}

#Preview("Coder Servers") {
    NavigationStack {
        CoderServersListView(
            model: CoderServersModel(
                store: PreviewCoderServerStore(),
                connectionStore: PreviewConnectionStore()
            )
        )
    }
    .terminalStyle()
}

private actor PreviewCoderServerStore: CoderServerStoreProtocol {
    private var servers: [CoderServer] = [
        try! CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: "prod"
        ),
        try! CoderServer(
            name: "Staging",
            baseURL: URL(string: "https://staging.example.com")!,
            tokenKeychainTag: "staging"
        ),
    ]

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { servers }
    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        servers.first { $0.id == id }
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {
        servers.removeAll { $0.id == server.id }
        servers.append(server)
    }

    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        servers.removeAll { $0.id == id }
    }
}

private actor PreviewConnectionStore: ConnectionStoreProtocol {
    func loadConnections() async throws(PersistenceError) -> [Connection] { [] }
    func connection(id: UUID) async throws(PersistenceError) -> Connection? { nil }
    func save(_ connection: Connection) async throws(PersistenceError) {}
    func deleteConnection(id: UUID) async throws(PersistenceError) {}
}

struct CoderServerRow: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let server: CoderServer

    var body: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(server.name)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .lineLimit(1)

                Text(server.baseURL.absoluteString)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(1)
            }

            Spacer()

            Label("Configured", systemImage: "checkmark.shield")
                .font(typography.caption)
                .foregroundColor(colors.success)
                .accessibilityIdentifier("coder-server-status-\(sanitized(server.name))")
        }
        .padding(.vertical, spacing.xxs)
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}
