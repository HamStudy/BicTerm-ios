import BicTermCore
import SwiftUI

struct HopEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    /// Snapshot of the incoming draft; dirty = working draft differs, so a
    /// hop reverted to its original values cancels without prompting.
    @State private var originalDraft: HopDraft
    @State private var showDiscardConfirmation = false
    @State private var draft: HopDraft
    let isEditing: Bool
    let onFinish: (HopDraft) -> Void
    /// Validation timing mirrors ConnectionEditorView: an error renders only
    /// after its field was edited (or password mode chosen) or a save was
    /// attempted — a pristine blank hop never shows red. Save gating stays
    /// eager via `draft.isComplete`.
    @State private var touchedFields: Set<FocusField> = []
    @State private var saveAttempted = false
    @FocusState private var focus: FocusField?

    enum FocusField {
        case host, port, username, password
    }

    init(
        draft: HopDraft,
        isEditing: Bool,
        onFinish: @escaping (HopDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self._originalDraft = State(initialValue: draft)
        self.isEditing = isEditing
        self.onFinish = onFinish
    }

    private var isDirty: Bool {
        draft != originalDraft
    }

    private func cancelTapped() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var hostError: String? {
        visibleError(
            draft.host.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Host is required"
                : (ConnectionFieldValidation.isValidHostname(draft.host) ? nil : "Invalid hop hostname"),
            for: .host
        )
    }

    private var portError: String? {
        visibleError(HopPort.errorDescription(draft.port, field: "Port"), for: .port)
    }

    private var usernameError: String? {
        visibleError(ConnectionFieldValidation.usernameError(draft.username), for: .username)
    }

    private func visibleError(_ error: String?, for field: FocusField) -> String? {
        guard touchedFields.contains(field) || saveAttempted else { return nil }
        return error
    }

    /// Wraps a field binding so the first edit marks the field touched,
    /// arming its inline error from that keystroke on.
    private func touchedBinding(_ binding: Binding<String>, field: FocusField) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                touchedFields.insert(field)
                binding.wrappedValue = newValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hop") {
                    field("Host", text: $draft.host, identifier: "hop-field-host", error: hostError, focus: .host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    field("Port", text: $draft.port, identifier: "hop-field-port", error: portError, focus: .port)
                        .keyboardType(.default)

                    field("Username", text: $draft.username, identifier: "hop-field-username", error: usernameError, focus: .username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Authentication", selection: Binding(
                        get: { draft.authMethod },
                        set: {
                            draft.switchAuthMethod(to: $0)
                            if $0 == .password { touchedFields.insert(.password) }
                        }
                    )) {
                        Text("Key").tag(AuthMethod.publickey)
                        Text("Password").tag(AuthMethod.password)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("hop-auth-method-picker")

                    if draft.authMethod == .password {
                        VStack(alignment: .leading, spacing: spacing.xxxs) {
                            HStack {
                                Text("Password")
                                    .font(typography.body)
                                    .foregroundColor(colors.foreground)
                                Spacer()
                                SecureField("", text: touchedBinding($draft.passwordInput, field: .password))
                                    .font(typography.body)
                                    .foregroundColor(colors.foreground)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityLabel("Password")
                                    .accessibilityIdentifier("hop-password-field")
                            }
                            if draft.hasSavedPassword, draft.passwordInput.isEmpty {
                                Text("Saved in Keychain")
                                    .font(typography.caption)
                                    .foregroundColor(colors.success)
                                    .accessibilityIdentifier("hop-password-saved-badge")
                            }
                        }
                    } else {
                        NavigationLink {
                            KeyPickerView(
                                selectedReference: draft.keyReference
                            ) { selected in
                                draft.keyReference = selected.reference
                                draft.keyLabel = selected.label
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: spacing.xxxs) {
                                Text("Authentication Key")
                                    .font(typography.body)
                                    .foregroundColor(colors.foreground)
                                Text(draft.keyReference.isEmpty ? "Select a key" : draft.keyLabel)
                                    .font(typography.caption)
                                    .foregroundColor(
                                        draft.keyReference.isEmpty
                                            ? (saveAttempted ? colors.error : colors.dimmed)
                                            : colors.accent
                                    )
                            }
                        }
                        .accessibilityIdentifier("hop-key-selector")
                    }
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
            .navigationTitle(isEditing ? "Edit Hop" : "Add Hop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancelTapped() }
                        .accessibilityIdentifier("cancel-hop")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveAttempted = true
                        originalDraft = draft
                        onFinish(draft)
                        dismiss()
                    }
                    .disabled(!draft.isComplete)
                    .accessibilityIdentifier("save-hop")
                    .fontWeight(.semibold)
                }
            }
        }
        .environment(\.terminalColors, colors)
        .environment(\.terminalTypography, typography)
        .environment(\.terminalSpacing, spacing)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(
            "Discard Changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
                .accessibilityIdentifier("discard-confirm")
            // No .cancel role: iOS 26 compact dialogs render a cancel-role
            // action as outside-tap only, leaving VoiceOver/tests no button.
            Button("Keep Editing") {}
                .accessibilityIdentifier("discard-cancel")
        }
        // See ConnectionEditorView: the identifier rides the sheet root and
        // is present only while the discard dialog is showing.
        .accessibilityIdentifier(showDiscardConfirmation ? "discard-changes-dialog" : "hop-editor")
    }

    private func field(
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
                TextField("", text: touchedBinding(text, field: focus))
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: focus)
                    .submitLabel(.done)
                    .onSubmit { self.focus = nil }
                    .accessibilityLabel(label)
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
}
