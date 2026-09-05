import BicTermCore
import SwiftUI

struct HopEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    @State private var draft: HopDraft
    let isEditing: Bool
    let keys: [KeyMetadata]
    let onFinish: (HopDraft) -> Void
    @FocusState private var focus: FocusField?

    enum FocusField {
        case host, port, username
    }

    init(
        draft: HopDraft,
        isEditing: Bool,
        keys: [KeyMetadata],
        onFinish: @escaping (HopDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.isEditing = isEditing
        self.keys = keys
        self.onFinish = onFinish
    }

    private var hostError: String? {
        draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Host is required"
            : (ConnectionFieldValidation.isValidHostname(draft.host) ? nil : "Invalid hop hostname")
    }

    private var portError: String? {
        HopPort.errorDescription(draft.port, field: "Port")
    }

    private var usernameError: String? {
        ConnectionFieldValidation.usernameError(draft.username)
    }

    private var keyError: String? {
        draft.keyReference.isEmpty ? "Select a key" : nil
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
                        .keyboardType(.numberPad)

                    field("Username", text: $draft.username, identifier: "hop-field-username", error: usernameError, focus: .username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    NavigationLink {
                        KeyPickerView(
                            keys: keys,
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
                            Text(draft.keyReference.isEmpty ? (keyError ?? "Select a key") : draft.keyLabel)
                                .font(typography.caption)
                                .foregroundColor(draft.keyReference.isEmpty ? colors.error : colors.accent)
                        }
                    }
                    .accessibilityIdentifier("hop-key-selector")
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
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-hop")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
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
                TextField("", text: text)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: focus)
                    .submitLabel(.done)
                    .onSubmit { self.focus = nil }
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
