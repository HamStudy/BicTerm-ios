import BicTermCore
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    let existing: Connection?
    /// Duplicate-as-new pre-fill source. Its values seed a fresh draft while
    /// `existing` stays nil, so the editor keeps add-flow semantics: "New
    /// Connection" title, Save inserts a new connection, and the
    /// orphaned-password cleanup never treats the source's (shared)
    /// Keychain tags as replaced.
    let seed: Connection?
    let model: ConnectionsModel
    let onConnect: (Connection) -> Void

    @State private var draft = ConnectionDraft()
    /// Snapshot captured once on first appear (post-populate); dirty = working
    /// draft differs from it, so reverted edits read clean again.
    @State private var originalDraft: ConnectionDraft?
    @State private var showDiscardConfirmation = false
    @State private var hopSheetTarget: HopSheetTarget?
    @State private var hopLimitMessage: String?
    @State private var saveError: String?
    @State private var isSaving = false
    /// Validation timing: a field's error renders only after the field was
    /// edited (or its credential mode chosen) or a save was attempted — a
    /// pristine blank form never shows red. Save-button gating stays eager
    /// (`canSubmit`); a disabled Save needs no error text to explain itself.
    @State private var touchedFields: Set<FocusField> = []
    @State private var saveAttempted = false
    @FocusState private var focus: FocusField?

    enum FocusField {
        case name, host, port, username, password, herdrSession
    }

    struct HopSheetTarget: Hashable, Identifiable {
        let index: Int?
        var id: String { index.map(String.init) ?? "new" }
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                authenticationSection
                if jumpChainSupported { jumpChainSection }
                protocolOptionsSection
                if draft.protocolID == ProtocolDescriptor.ssh.id { herdrSection }
                connectSection
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
            .navigationTitle(existing == nil ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancelTapped() }
                        .accessibilityIdentifier("cancel-editor")
                }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Save") { persist(connectAfterSave: false) }
                                .disabled(!canSubmit)
                                .accessibilityIdentifier("save-editor")
                                .fontWeight(.semibold)
                        }
            }
        .onAppear {
            // Populate once: onAppear refires when a pushed editor (key
            // picker, hop editor) pops back, and re-populating would reset
            // the in-progress draft to the persisted values.
            if originalDraft == nil {
                populateDraft()
                originalDraft = draft
                Task { await probePasswords() }
            }
        }
            .onChange(of: draft) {
                saveError = nil
            }
            .navigationDestination(item: $hopSheetTarget) { target in
                HopEditorView(
                    draft: target.index.map { draft.hops[$0] } ?? HopDraft(),
                    isEditing: target.index != nil
                ) { finished in
                    if let index = target.index {
                        draft.hops[index] = finished
                    } else {
                        draft.hops.append(finished)
                    }
                }
            }
        }
        .environment(\.terminalColors, colors)
        .environment(\.terminalTypography, typography)
        .environment(\.terminalSpacing, spacing)
        .presentationSizing(.page)
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
        // System action sheets don't inherit SwiftUI identifiers; expose the
        // dialog-presenting state on the sheet root instead (never present
        // while the editor is clean).
        .accessibilityIdentifier(showDiscardConfirmation ? "discard-changes-dialog" : "connection-editor")
    }

    private var isDirty: Bool {
        guard let originalDraft else { return false }
        return draft != originalDraft
    }

    private func probePasswords() async {
        let tag = draft.passwordTag
        if !tag.isEmpty {
            let found = (try? await AppServices.shared.passwordStore.password(for: tag)) != nil
            if draft.passwordTag == tag {
                draft.hasSavedPassword = found
                draft.passwordEntryMissing = !found
                originalDraft?.hasSavedPassword = found
                originalDraft?.passwordEntryMissing = !found
            }
        }
        for hop in draft.hops where !hop.passwordTag.isEmpty {
            let found = (try? await AppServices.shared.passwordStore.password(for: hop.passwordTag)) != nil
            if let index = draft.hops.firstIndex(where: { $0.id == hop.id && $0.passwordTag == hop.passwordTag }) {
                draft.hops[index].hasSavedPassword = found
                draft.hops[index].passwordEntryMissing = !found
                draft.hops[index].passwordWasProbed = true
            }
            if let index = originalDraft?.hops.firstIndex(where: { $0.id == hop.id }) {
                originalDraft?.hops[index].hasSavedPassword = found
                originalDraft?.hops[index].passwordEntryMissing = !found
                originalDraft?.hops[index].passwordWasProbed = true
            }
        }
    }

    private func cancelTapped() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var descriptor: ProtocolDescriptor? {
        model.descriptor(forProtocolID: draft.protocolID)
    }

    private var jumpChainSupported: Bool {
        descriptor?.supportsJumpChain ?? false
    }

    private var identitySection: some View {
        Section("Connection") {
            labeledField("Name", text: $draft.name, identifier: "field-name", error: visibleError(draft.nameError, for: .name), focus: .name)

            Picker("Protocol", selection: $draft.protocolID) {
                ForEach(protocolChoices) { candidate in
                    Text(candidate.title).tag(candidate.id)
                }
            }
            .pickerStyle(.menu)
            .tint(colors.accent)
            .accessibilityIdentifier("protocol-picker")
            .onChange(of: draft.protocolID) { _, newID in
                focus = nil
                if let newDescriptor = model.descriptor(forProtocolID: newID) {
                    if !newDescriptor.supportsJumpChain { draft.hops = [] }
                    draft.port = String(newDescriptor.defaultPort)
                }
            }

            if descriptor == nil {
                Label(
                    "This protocol isn't available in this build",
                    systemImage: "exclamationmark.triangle"
                )
                .font(typography.caption)
                .foregroundColor(colors.error)
            }

            labeledField("Host", text: $draft.host, identifier: "field-host", error: visibleError(draft.hostError, for: .host), focus: .host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            labeledField("Port", text: $draft.port, identifier: "field-port", error: visibleError(draft.portError, for: .port), focus: .port)
                .keyboardType(UIDevice.current.userInterfaceIdiom == .pad ? .numbersAndPunctuation : .numberPad)

            labeledField("Username", text: $draft.username, identifier: "field-username", error: visibleError(draft.usernameError, for: .username), focus: .username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
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

    private struct ProtocolChoice: Identifiable {
        let id: String
        let title: String
    }

    private var protocolChoices: [ProtocolChoice] {
        var choices = model.protocols.compactMap { descriptor -> ProtocolChoice? in
            guard ConnectionType(rawValue: descriptor.id) != nil else { return nil }
            return ProtocolChoice(id: descriptor.id, title: descriptor.displayName)
        }
        if !choices.contains(where: { $0.id == draft.protocolID }) {
            choices.append(ProtocolChoice(
                id: draft.protocolID,
                title: "\(draft.protocolID) (Unavailable)"
            ))
        }
        return choices
    }

    private var canSubmit: Bool {
        draft.isValid && descriptor != nil && !isSaving
    }

    private var authenticationSection: some View {
        Section {
            if draft.protocolID == ProtocolDescriptor.ssh.id {
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
                .accessibilityIdentifier("auth-method-picker")
            }

            if draft.authMethod == .password, draft.protocolID == ProtocolDescriptor.ssh.id {
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
                            .accessibilityIdentifier("password-field")
                    }
                    if draft.hasSavedPassword, draft.passwordInput.isEmpty {
                        Text("Saved on this device")
                            .font(typography.caption)
                            .foregroundColor(colors.success)
                            .accessibilityIdentifier("password-saved-badge")
                    } else if draft.passwordEntryMissing, draft.passwordInput.isEmpty {
                        Text("Saved password missing — re-enter it or you'll be asked when connecting")
                            .font(typography.caption)
                            .foregroundColor(colors.error)
                            .accessibilityIdentifier("password-field-error")
                    } else {
                        Text(draft.passwordInput.isEmpty
                             ? "You'll be asked for the password when connecting"
                             : "Will be saved in this device's Keychain when you tap Save")
                            .font(typography.caption)
                            .foregroundStyle(colors.dimmed)
                            .accessibilityIdentifier("password-field-status")
                    }
                }
            } else {
                keyPickerRow
            }
        } header: {
            Text("Authentication")
        } footer: {
            if draft.authMethod == .password, draft.protocolID == ProtocolDescriptor.ssh.id {
                Text(draft.hasSavedPassword
                     ? "Leave the field blank to keep the saved password, or type a replacement. Passwords stay in this device's Keychain, protected when locked; they don't transfer to another device."
                     : "Password is optional. Leave it blank to be asked when connecting. Typed passwords are saved in this device's Keychain, protected when locked; they don't transfer to another device.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            } else {
                Text("Keys are referenced by label and fingerprint. Private key material never leaves the keychain.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
        }
    }

    private var keyPickerRow: some View {
        NavigationLink {
            KeyPickerView(selectedReference: draft.keyReference) { selected in
                draft.keyReference = selected.reference
                draft.keyLabel = selected.label
            }
        } label: {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text("Authentication Key")
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                if draft.keyReference.isEmpty {
                    Text(saveAttempted ? (draft.keyError ?? "Select a key") : "Select a key")
                        .font(typography.caption)
                        .foregroundColor(saveAttempted && draft.keyError != nil ? colors.error : colors.dimmed)
                } else {
                    Text(draft.keyLabel.isEmpty ? draft.keyReference : draft.keyLabel)
                        .font(typography.caption)
                        .foregroundColor(colors.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityIdentifier("key-selector")
    }

    private var jumpChainSection: some View {
        Section {
            ForEach(Array(draft.hops.enumerated()), id: \.element.id) { index, hop in
                hopRow(index: index, hop: hop)
            }
            .onMove { source, destination in
                draft.hops.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                draft.hops.remove(atOffsets: offsets)
            }

            Button {
                addHopTapped()
            } label: {
                Label("Add Hop", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("add-hop")
            .foregroundColor(colors.accent)
        } header: {
            Text("Jump Chain (\(draft.hops.count)/\(Connection.maximumJumpChainLength))")
        } footer: {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                if let hopLimitMessage {
                    Text(hopLimitMessage)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("hop-limit-message")
                }
                if let cycleWarning {
                    Text(cycleWarning)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("cycle-warning")
                }
            }
        }
    }

    private var cycleWarning: String? {
        draft.hasCycle
            ? "Duplicate host and port in the chain — this would create a cycle"
            : nil
    }

    private func hopRow(index: Int, hop: HopDraft) -> some View {
        HStack(spacing: spacing.sm) {
            Text("\(index + 1)")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text("\(hop.host):\(hop.port)")
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("hop-\(index)-host")
                Text("\(hop.username) · \(hopCredentialSummary(hop))")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("hop-\(index)-credential")
            }

            Spacer()

            Button("Edit") { hopSheetTarget = HopSheetTarget(index: index) }
                .font(typography.caption)
                .foregroundColor(colors.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("edit-hop-\(index)")

            Button {
                deleteHop(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .foregroundColor(colors.error)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Delete hop")
            .accessibilityIdentifier("delete-hop-\(index)")
        }
        .buttonStyle(.borderless)
    }

    private func hopCredentialSummary(_ hop: HopDraft) -> String {
        switch hop.authMethod {
        case .publickey:
            hop.keyLabel.isEmpty ? "no key" : hop.keyLabel
        case .password:
            "Password"
        }
    }

    private func addHopTapped() {        guard draft.hops.count < Connection.maximumJumpChainLength else {
            hopLimitMessage = "Maximum \(Connection.maximumJumpChainLength) hops"
            return
        }
        hopLimitMessage = nil
        hopSheetTarget = HopSheetTarget(index: nil)
    }

    private func deleteHop(at index: Int) {
        guard draft.hops.indices.contains(index) else { return }
        draft.hops.remove(at: index)
        if draft.hops.count < Connection.maximumJumpChainLength {
            hopLimitMessage = nil
        }
    }

    private var protocolOptionsSection: some View {
        Section("Protocol Options") {
            if descriptor?.supportsAgentForwarding == true {
                Toggle(isOn: $draft.agentForwarding) {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text("Agent Forwarding")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Text("Forward the local SSH agent through this session")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                    }
                }
                .tint(colors.accent)
                .accessibilityIdentifier("toggle-agent-forwarding")
            } else {
                Text("No options for this protocol")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
        }
    }

    private var herdrSection: some View {
        Section {
            Toggle(isOn: $draft.herdrEnabled) {
                VStack(alignment: .leading, spacing: spacing.xxxs) {
                    Text("Use Herdr")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    Text("Connect to this machine's herdr workspace instead of a single shell")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
            }
            .tint(colors.accent)
            .accessibilityIdentifier("herdr-toggle")

            if draft.herdrEnabled {
                labeledField(
                    "Remote Session (optional)",
                    text: $draft.herdrSessionName,
                    identifier: "herdr-session-field",
                    error: draft.herdrSessionError,
                    focus: .herdrSession
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        } header: {
            Text("Herdr")
        } footer: {
            Text("Connecting opens this machine's herdr workspace (tabs and panes) instead of a plain terminal. The host must already run herdr 0.9 or newer; this app never installs or updates it.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .accessibilityIdentifier("herdr-section-footer")
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                persist(connectAfterSave: true)
            } label: {
                Label("Save & Connect", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canSubmit)
            .tint(colors.success)
            .accessibilityIdentifier("connect-button")

            if let saveError {
                Text(saveError)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .accessibilityIdentifier("save-error")
            }
        }
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

    private func populateDraft() {
        if let existing {
            draft = ConnectionDraft(
                connection: existing,
                keyLabel: model.keyLabel(forReference: existing.customKeys?.first ?? "")
            )
            applyHopKeyLabels(from: existing)
        } else if let seed {
            draft = ConnectionDraft(
                duplicating: seed,
                name: model.nextDuplicateName(of: seed.name),
                keyLabel: model.keyLabel(forReference: seed.customKeys?.first ?? "")
            )
            applyHopKeyLabels(from: seed)
        }
    }

    /// Password hops carry Keychain tags, never key references, so the key
    /// list resolves no label for them and their label stays empty.
    private func applyHopKeyLabels(from connection: Connection) {
        for index in draft.hops.indices {
            draft.hops[index].keyLabel =
                model.keyLabel(forReference: connection.jumpChain[index].customKeys?.first ?? "") ?? ""
        }
    }

    private func persist(connectAfterSave: Bool) {
        saveAttempted = true
        saveError = nil
        do {
            let connection = try draft.makeConnection()
            guard descriptor != nil else {
                saveError = "This protocol is unavailable in this build. Choose an available protocol before saving."
                return
            }
            isSaving = true
            Task {
                if let storeError = await storePendingPasswords() {
                    isSaving = false
                    saveError = storeError
                    return
                }
                let result = await model.persist(connection)
                isSaving = false
                switch result {
                case .success:
                    await deleteOrphanedPasswordEntries(replacedBy: connection)
                    originalDraft = draft
                    if connectAfterSave { onConnect(connection) }
                    dismiss()
                case let .failure(error):
                    saveError = "Couldn't save the connection. \(error.localizedDescription) Check available storage and try again."
                }
            }
        } catch {
            saveError = "Review the connection details before saving. \(error.localizedDescription)"
        }
    }

    /// New/changed password inputs for the destination and hops. Saved
    /// passwords that weren't retyped are simply kept (overwrite would be a
    /// no-op); only fields carrying fresh input produce a write.
    private var pendingPasswordWrites: [(tag: String, password: String)] {
        var writes: [(tag: String, password: String)] = []
        if draft.authMethod == .password, !draft.passwordInput.isEmpty {
            writes.append((tag: draft.passwordTag, password: draft.passwordInput))
        }
        for hop in draft.hops where hop.authMethod == .password && !hop.passwordInput.isEmpty {
            writes.append((tag: hop.passwordTag, password: hop.passwordInput))
        }
        return writes
    }

    /// A typed password must not be silently discarded when Keychain saving
    /// fails; leave the draft open rather than saving only its tag.
    private func storePendingPasswords() async -> String? {
        for write in pendingPasswordWrites {
            do {
                try await AppServices.shared.passwordStore.save(write.password, for: write.tag)
            } catch {
                return "Couldn't store the SSH password in the Keychain. The connection was not saved — try again."
            }
        }
        return nil
    }

    /// Only tags the persisted model no longer references are deleted; tags
    /// still in use (including entries shared via connection duplication) are
    /// retained.
    private func deleteOrphanedPasswordEntries(replacedBy connection: Connection) async {
        let oldTags = existing.map(ConnectionsModel.passwordTags(in:)) ?? []
        let liveTags = ConnectionsModel.passwordTags(in: connection)
        for tag in oldTags where !liveTags.contains(tag) {
            try? await AppServices.shared.passwordStore.deletePassword(for: tag)
        }
    }
}
