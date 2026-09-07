import BicTermCore
import SwiftUI

struct CoderServerEditorView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dismiss) private var dismiss

    let model: CoderServersModel
    let existing: CoderServer?
    let onComplete: (CoderServerEditorResult) -> Void

    @State private var draft = CoderServerDraft()
    @State private var validationError: String?
    @State private var isValidating = false
    @FocusState private var focus: FocusField?

    enum FocusField: Hashable {
        case name, url, token
    }

    init(
        model: CoderServersModel,
        existing: CoderServer?,
        onComplete: @escaping (CoderServerEditorResult) -> Void
    ) {
        self.model = model
        self.existing = existing
        self.onComplete = onComplete
        if let existing {
            _draft = State(initialValue: CoderServerDraft(server: existing))
        }
    }

    private var maskedTokenHint: String? {
        guard existing != nil, draft.token.isEmpty else { return nil }
        return "Token saved. Enter a new token to replace it."
    }

    var body: some View {
        Form {
            Section("Server") {
                labeledField(
                    "Name",
                    text: $draft.name,
                    identifier: "coder-server-name",
                    error: draft.nameError,
                    focus: .name
                )

                labeledField(
                    "URL",
                    text: $draft.urlString,
                    identifier: "coder-server-url",
                    error: draft.urlError,
                    focus: .url
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
            }

            Section("Token") {
                if let maskedTokenHint {
                    Text(maskedTokenHint)
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                        .accessibilityIdentifier("coder-token-hint")
                }

                SecureField("Coder session token", text: $draft.token)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .token)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .accessibilityIdentifier("coder-server-token")

                if let validationError {
                    Text(validationError)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("coder-server-validation-error")
                }
            }

            Section {
                Button {
                    validateAndSave()
                } label: {
                    HStack(spacing: spacing.xs) {
                        if isValidating {
                            ProgressView()
                                .tint(colors.accent)
                            Text("Validating server...")
                                .font(typography.caption)
                        } else {
                            Text("Validate & Save")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit || isValidating)
                .foregroundColor(colors.accent)
                .listRowBackground(colors.background)
                .accessibilityIdentifier("coder-server-validate-save")
            }
        }
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .navigationTitle(existing == nil ? "Add Coder Server" : "Edit Coder Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { complete(.cancelled) }
                    .accessibilityIdentifier("coder-server-cancel")
            }
        }
        .defaultFocus($focus, .name)
        .environment(\.terminalColors, colors)
        .environment(\.terminalTypography, typography)
        .environment(\.terminalSpacing, spacing)
        .onChange(of: draft.name) {
            validationError = nil
        }
        .onChange(of: draft.urlString) {
            validationError = nil
        }
    }

    private var canSubmit: Bool {
        draft.isComplete
    }

    private func labeledField(
        _ label: String,
        text: Binding<String>,
        identifier: String,
        error: String?,
        focus: FocusField
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing.xxxs) {
            HStack {
                Text(label)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                Spacer()
                TextField("", text: text)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: focus)
                    .submitLabel(.next)
                    .onSubmit { advanceFocus(from: focus) }
                    .accessibilityIdentifier(identifier)
            }
            if let error {
                Text(error)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .accessibilityIdentifier("\(identifier)-error")
            }
        }
    }

    private func advanceFocus(from current: FocusField) {
        switch current {
        case .name: focus = .url
        case .url: focus = .token
        case .token: focus = nil
        }
    }

    @MainActor
    private func validateAndSave() {
        validationError = nil
        guard draft.isComplete else { return }

        let server: CoderServer
        do {
            server = try draft.makeServer()
        } catch {
            validationError = "Check the server address and try again."
            return
        }

        let replacementToken = draft.token.isEmpty ? nil : draft.token
        draft.token = ""
        focus = nil

        isValidating = true
        Task { @MainActor in
            await Task.yield()
            let result = await model.save(server, replacementToken: replacementToken)
            isValidating = false
            switch result {
            case .success:
                complete(.saved)
            case .failure(let error):
                validationError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func complete(_ result: CoderServerEditorResult) {
        draft.token = ""
        onComplete(result)
    }
}

#Preview("New Server") {
    NavigationStack {
        CoderServerEditorView(
            model: CoderServersModel(
                store: PreviewCoderServerStore(),
                connectionStore: PreviewConnectionStore()
            ),
            existing: nil,
            onComplete: { _ in }
        )
    }
    .terminalStyle()
}

#Preview("Edit Server") {
    NavigationStack {
        CoderServerEditorView(
            model: CoderServersModel(
                store: PreviewCoderServerStore(),
                connectionStore: PreviewConnectionStore()
            ),
            existing: try? CoderServer(
                name: "Preview",
                baseURL: URL(string: "https://preview.example.com")!,
                tokenKeychainTag: "preview"
            ),
            onComplete: { _ in }
        )
    }
    .terminalStyle()
}

private actor PreviewCoderServerStore: CoderServerStoreProtocol {
    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { [] }
    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? { nil }
    func save(_ server: CoderServer) async throws(PersistenceError) {}
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {}
}

private actor PreviewConnectionStore: ConnectionStoreProtocol {
    func loadConnections() async throws(PersistenceError) -> [Connection] { [] }
    func connection(id: UUID) async throws(PersistenceError) -> Connection? { nil }
    func save(_ connection: Connection) async throws(PersistenceError) {}
    func deleteConnection(id: UUID) async throws(PersistenceError) {}
}
