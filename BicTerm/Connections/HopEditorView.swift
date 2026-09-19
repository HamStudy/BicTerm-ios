import BicTermCore
import SwiftUI

struct HopEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss
    @Environment(KeyStore.self) private var keyStore
    @Environment(KeyAvailabilityPreferences.self) private var preferences

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

    private var offeredKeyCount: Int {
        KeyOfferResolver().resolve(
            KeyOfferRequest(offersKeys: draft.offersKeys, customKeys: draft.customKeys,
                            hardwareKeysEnabledByDefault: preferences.hardwareOfferedByDefault),
            keys: keyStore.keys.map(\.metadata)
        ).count
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

            }
            Section("Keys") {
                Toggle("Offer Keys", isOn: $draft.offersKeys)
                    .accessibilityIdentifier("hop-offer-keys-toggle")
                NavigationLink("Customize") {
                    KeyPickerView(customKeys: $draft.customKeys)
                }
                .disabled(!draft.offersKeys)
                .accessibilityIdentifier("hop-key-selector")
                if offeredKeyCount > 5 {
                    Text("\(offeredKeyCount) keys will be offered. Many servers allow only 6 authentication attempts and may disconnect before later keys are tried.")
                        .font(typography.caption)
                        .foregroundStyle(colors.dimmed)
                        .accessibilityIdentifier("hop-offer-count-warning")
                }
            }
            Section("Password") {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        HStack {
                            Text("Password")
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                            Spacer()
                            SecureField("", text: touchedBinding($draft.passwordInput, field: .password))
                                // Opt out of the system password-vault save flow; BicTerm owns persistence.
                                .textContentType(.oneTimeCode)
                                .focused($focus, equals: .password)
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Password")
                                .accessibilityIdentifier("hop-password-field")
                        }
                        if draft.removePasswordOnSave, draft.passwordInput.isEmpty {
                            Text("Password will be removed when you save the connection")
                                .font(typography.caption)
                                .accessibilityIdentifier("hop-password-removal-status")
                        } else if draft.hasSavedPassword, draft.passwordInput.isEmpty {
                            Text("Saved on this device")
                                .font(typography.caption)
                                .foregroundColor(colors.success)
                                .accessibilityIdentifier("hop-password-saved-badge")
                        } else if draft.passwordEntryMissing, draft.passwordInput.isEmpty {
                            Text("Saved password missing — re-enter it, or you'll be prompted if this hop requests a password")
                                .font(typography.caption)
                                .foregroundStyle(colors.error)
                                .accessibilityIdentifier("hop-password-field-error")
                        } else {
                            Text(draft.passwordInput.isEmpty
                                 ? "No password saved — you'll be prompted if this hop requests one"
                                 : "Will be saved in this device's Keychain when you tap Save in the connection editor")
                                .font(typography.caption)
                                .foregroundStyle(colors.dimmed)
                        }
                    }
                if !draft.removePasswordOnSave && (draft.hasSavedPassword || draft.passwordTag != nil) {
                    Button("Remove Saved Password", role: .destructive) { draft.stagePasswordRemoval() }
                        .accessibilityIdentifier("hop-remove-saved-password")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            guard !draft.passwordWasProbed, !draft.removePasswordOnSave, let tag = draft.passwordTag else { return }
            let found = (try? await AppServices.shared.passwordStore.password(for: tag)) != nil
            guard draft.passwordTag == tag else { return }
            draft.hasSavedPassword = found
            draft.passwordEntryMissing = !found
            draft.passwordWasProbed = true
            originalDraft.hasSavedPassword = found
            originalDraft.passwordEntryMissing = !found
            originalDraft.passwordWasProbed = true
        }
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
        // Pushed onto the connection editor's stack; the back button is
        // hidden so the discard-guarded Cancel is the only visible exit and
        // a dirty hop is never abandoned without the "Discard Changes?"
        // prompt. The system edge-swipe pop gesture has no SwiftUI guard
        // hook and stays an unguarded exit — intercepting it would require
        // UIKit gesture introspection, rejected here as out of scope.
        .navigationBarBackButtonHidden(true)
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
            }
        }
        .environment(\.terminalColors, colors)
        .environment(\.terminalTypography, typography)
        .environment(\.terminalSpacing, spacing)
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
        // See ConnectionEditorView: the identifier rides the pushed editor's
        // root and is present only while the discard dialog is showing.
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
