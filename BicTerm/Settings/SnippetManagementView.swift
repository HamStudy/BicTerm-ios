import BicTermCore
import SwiftUI

/// Settings-side management of GLOBAL snippets: list, create, edit,
/// delete — every mutation goes through the shared snippet store.
/// Connection-scoped snippets belong to their connection and surface in
/// that connection's terminal scenes instead. Saving a snippet NEVER
/// sends bytes to any session.
@MainActor
@Observable
final class SnippetManagementModel {
    private let store: any SnippetStoreProtocol

    private(set) var snippets: [Snippet] = []
    private(set) var loadError: String?

    init(store: (any SnippetStoreProtocol)? = nil) {
        self.store = store ?? AppServices.shared.snippetStore
    }

    func reload() async {
        do {
            snippets = try await store.loadSnippets().filter { $0.connectionID == nil }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Inserts or updates (by id) a global snippet. Returns nil on
    /// success, or a user-facing error message — empty fields, a
    /// duplicate name within the global scope, or a store failure —
    /// for the editor to surface inline.
    func save(name: String, command: String, editing: Snippet?) async -> String? {
        do {
            let snippet: Snippet
            if let editing {
                snippet = try Snippet(id: editing.id, name: name, command: command)
            } else {
                snippet = try Snippet(name: name, command: command)
            }
            try await store.save(snippet)
            await reload()
            return nil
        } catch let error as SnippetValidationError {
            switch error {
            case .emptyName: return "Name is required."
            case .emptyCommand: return "Command is required."
            }
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ snippet: Snippet) async {
        try? await store.deleteSnippet(id: snippet.id)
        await reload()
    }
}

/// The Settings → Snippets surface: the global snippet list with
/// swipe-to-delete, an add button, and a name+command editor whose
/// validation surfaces the store's duplicate-name and empty-field
/// errors inline.
struct SnippetManagementView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography

    @State private var model = SnippetManagementModel()
    @State private var editorTarget: SnippetEditorTarget?

    private struct SnippetEditorTarget: Identifiable {
        let snippet: Snippet?
        let id: UUID

        init(snippet: Snippet?) {
            self.snippet = snippet
            self.id = snippet?.id ?? UUID()
        }
    }

    var body: some View {
        List {
            if let loadError = model.loadError {
                Section {
                    Text(loadError)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("snippet-manage-load-error")
                }
            }
            Section {
                if model.snippets.isEmpty {
                    Text("No snippets yet. Tap + to add one.")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                }
                ForEach(model.snippets) { snippet in
                    Button {
                        editorTarget = SnippetEditorTarget(snippet: snippet)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name)
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                            Text(snippet.command)
                                .font(typography.caption)
                                .foregroundColor(colors.dimmed)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("snippet-manage-row-\(sanitized(snippet.name))")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.delete(snippet) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Global")
            } footer: {
                Text("Global snippets are available in every terminal session. Connection-scoped snippets appear in that connection's session menu.")
            }
            .listRowBackground(colors.background)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = SnippetEditorTarget(snippet: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Add Snippet")
                .accessibilityIdentifier("snippet-add")
            }
        }
        .sheet(item: $editorTarget) { target in
            SnippetEditorSheet(model: model, existing: target.snippet)
        }
        .task { await model.reload() }
        .accessibilityIdentifier("snippet-management-view")
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}

/// Create/edit form for one global snippet: name and command fields,
/// Save persisting through the management model, and validation errors
/// (empty fields, duplicate names) surfaced inline — never a silent
/// dismissal.
private struct SnippetEditorSheet: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.dismiss) private var dismiss

    let model: SnippetManagementModel
    let existing: Snippet?

    @State private var name: String
    @State private var command: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(model: SnippetManagementModel, existing: Snippet?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _command = State(initialValue: existing?.command ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("snippet-editor-name")
                    TextField("Command", text: $command, axis: .vertical)
                        .lineLimit(1...4)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("snippet-editor-command")
                } header: {
                    Text("Snippet")
                } footer: {
                    Text("Insert sends the command to the terminal without pressing Return. Run asks for confirmation, then sends it with Return.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(typography.caption)
                            .foregroundColor(colors.error)
                            .accessibilityIdentifier("snippet-editor-error")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Snippet" : "Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("snippet-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            let error = await model.save(name: name, command: command, editing: existing)
                            isSaving = false
                            if let error {
                                errorMessage = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("snippet-editor-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
