import BicTermCore
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    let existing: Connection?
    let model: ConnectionsModel
    let onConnect: (Connection) -> Void

    @State private var draft = ConnectionDraft()
    @State private var coderModel = CoderWorkspaceConnectionModel(
        coderServerStore: AppServices.shared.coderServerStore,
        coderTokenStore: AppServices.shared.coderTokenStore,
        clientFactory: AppServices.shared.coderClientFactory
    )
    @State private var hopSheetTarget: HopSheetTarget?
    @State private var coderServerToEdit: CoderServer?
    @State private var hopLimitMessage: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @FocusState private var focus: FocusField?

    enum FocusField {
        case name, host, port, username
    }

    struct HopSheetTarget: Identifiable {
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
                if draft.protocolID == "coder" { coderSection }
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
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-editor")
                }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Save") { persist(connectAfterSave: false) }
                                .disabled(!canSubmit)
                                .accessibilityIdentifier("save-editor")
                                .fontWeight(.semibold)
                        }
                        if case .unauthorized(let server) = coderModel.loadingState, draft.protocolID == "coder" {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    coderServerToEdit = server
                                } label: {
                                    Label("Reauthenticate", systemImage: "key.fill")
                                }
                                .foregroundColor(colors.error)
                                .accessibilityIdentifier("coder-reauthenticate")
                            }
                        }
            }
            .onAppear {
                populateDraft()
                prepareCoderModel()
            }
            .onChange(of: draft) {
                saveError = nil
            }
            .task(id: coderModel.selectedServerID) {
                guard draft.protocolID == "coder" else { return }
                await coderModel.loadWorkspaces()
            }
            .sheet(item: $hopSheetTarget) { target in
                HopEditorView(
                    draft: target.index.map { draft.hops[$0] } ?? HopDraft(),
                    isEditing: target.index != nil,
                    keys: model.keys
                ) { finished in
                    if let index = target.index {
                        draft.hops[index] = finished
                    } else {
                        draft.hops.append(finished)
                    }
                }
                .presentationDetents([.large])
            }
            .sheet(item: $coderServerToEdit) { server in
                NavigationStack {
                    CoderServerEditorView(
                        model: CoderServersModel(
                            store: AppServices.shared.coderServerStore,
                            connectionStore: AppServices.shared.connectionStore,
                            makeClient: AppServices.shared.coderClientFactory
                        ),
                        existing: server
                    ) { _ in
                        coderServerToEdit = nil
                    }
                }
            }
        }
        .environment(\.terminalColors, colors)
        .environment(\.terminalTypography, typography)
        .environment(\.terminalSpacing, spacing)
    }

    private var descriptor: ProtocolDescriptor? {
        model.descriptor(forProtocolID: draft.protocolID)
    }

    private var jumpChainSupported: Bool {
        descriptor?.supportsJumpChain ?? false
    }

    private var identitySection: some View {
        Section("Connection") {
            labeledField("Name", text: $draft.name, identifier: "field-name", error: draft.nameError, focus: .name)

            Picker("Protocol", selection: $draft.protocolID) {
                ForEach(protocolChoices) { candidate in
                    Text(candidate.title).tag(candidate.id)
                }
            }
            .pickerStyle(.menu)
            .tint(colors.accent)
            .accessibilityIdentifier("protocol-picker")
            .onChange(of: draft.protocolID) { _, newID in
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

            labeledField("Host", text: $draft.host, identifier: "field-host", error: draft.hostError, focus: .host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            labeledField("Port", text: $draft.port, identifier: "field-port", error: draft.portError, focus: .port)
                .keyboardType(.numberPad)

            labeledField("Username", text: $draft.username, identifier: "field-username", error: draft.usernameError, focus: .username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
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
        draft.isValid && descriptor != nil && !isSaving && coderSaveValid
    }

    private var coderSaveValid: Bool {
        guard draft.protocolID == "coder" else { return true }
        return coderModel.canSave
    }

    private var authenticationSection: some View {
        Section {
            NavigationLink {
                KeyPickerView(keys: model.keys) { selected in
                    draft.keyReference = selected.reference
                    draft.keyLabel = selected.label
                }
            } label: {
                VStack(alignment: .leading, spacing: spacing.xxxs) {
                    Text("Authentication Key")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    if draft.keyReference.isEmpty {
                        Text(draft.keyError ?? "Select a key")
                            .font(typography.caption)
                            .foregroundColor(draft.keyError == nil ? colors.dimmed : colors.error)
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
        } header: {
            Text("Authentication")
        } footer: {
            Text("Keys are referenced by label and fingerprint. Private key material never leaves the keychain.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
        }
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
                Text("\(hop.username) · \(hop.keyLabel.isEmpty ? "no key" : hop.keyLabel)")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Edit") { hopSheetTarget = HopSheetTarget(index: index) }
                .font(typography.caption)
                .foregroundColor(colors.accent)
                .accessibilityIdentifier("edit-hop-\(index)")

            Button {
                deleteHop(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .foregroundColor(colors.error)
            .accessibilityIdentifier("delete-hop-\(index)")
        }
        .buttonStyle(.borderless)
    }

    private func addHopTapped() {
        guard draft.hops.count < Connection.maximumJumpChainLength else {
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

    private var coderSection: some View {
        Section {
            if !coderModel.hasServers {
                Text(coderModel.noServersMessage)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .accessibilityIdentifier("coder-no-servers")
            } else {
                    Menu {
                    ForEach(coderModel.servers) { server in
                        Button(server.name) {
                            coderModel.selectServer(server)
                            draft.coderServerID = server.id.uuidString
                            draft.coderServerName = server.name
                            draft.coderWorkspaceID = ""
                            draft.coderWorkspaceName = ""
                        }
                    }
                } label: {
                    HStack {
                        Text("Coder Server")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Spacer()
                        Text(coderModel.selectedServerName.isEmpty ? "Select…" : coderModel.selectedServerName)
                            .font(typography.caption)
                            .foregroundColor(coderModel.selectedServerName.isEmpty ? colors.dimmed : colors.accent)
                    }
                }
                .accessibilityIdentifier("coder-server-picker")

                if coderModel.selectedServer != nil {
                    coderWorkspacePicker
                }
            }
        } header: {
            Text("Coder")
        } footer: {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                if let error = coderLoadingError {
                    Text(error)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("coder-workspace-error")
                }
                if let coderValidation = draft.coderValidationError {
                    Text(coderValidation)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("coder-validation-error")
                }
            }
        }
    }

    private var coderWorkspacePicker: some View {
        VStack(alignment: .leading, spacing: spacing.xxs) {
            HStack {
                Text("Workspace")
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                Spacer()
                if case .loading = coderModel.loadingState {
                    ProgressView()
                        .tint(colors.accent)
                        .accessibilityIdentifier("coder-workspaces-loading")
                }
            }

            if let error = networkOnlyError {
                Text(error)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .accessibilityIdentifier("coder-workspace-network-error")
            } else {
                ForEach(currentWorkspaces, id: \.id) { workspace in
                    Button {
                        if workspace.isConnectable {
                            coderModel.selectWorkspace(workspace)
                            draft.coderWorkspaceID = workspace.id.uuidString
                            draft.coderWorkspaceName = workspace.name
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: spacing.xxxs) {
                                Text(workspace.name)
                                    .font(typography.body)
                                    .foregroundColor(workspace.isConnectable ? colors.foreground : colors.dimmed)
                                Text(workspace.state.rawValue.capitalized)
                                    .font(typography.caption)
                                    .foregroundColor(colors.dimmed)
                            }
                            Spacer()
                            if draft.coderWorkspaceID == workspace.id.uuidString {
                                Image(systemName: "checkmark")
                                    .foregroundColor(colors.accent)
                            } else if !workspace.isConnectable {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(colors.dimmed)
                            }
                        }
                    }
                    .disabled(!workspace.isConnectable)
                    .accessibilityIdentifier("coder-workspace-\(workspace.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-"))")
                    .buttonStyle(.plain)
                    .opacity(workspace.isConnectable ? 1.0 : 0.8)
                }
            }
        }
    }

    private var currentWorkspaces: [CoderWorkspace] {
        switch coderModel.loadingState {
        case .loaded(let workspaces), .staleRevalidating(let workspaces):
            return workspaces
        default:
            return []
        }
    }

    private var coderLoadingError: String? {
        switch coderModel.loadingState {
        case .unreachable:
            return "Cannot reach the Coder server. Check the network or TLS settings."
        case .serverError(_, let statusCode):
            return "Coder returned an error (HTTP \(statusCode))."
        case .networkError, .empty, .idle, .loading, .loaded, .staleRevalidating, .unauthorized:
            return nil
        }
    }

    private var networkOnlyError: String? {
        switch coderModel.loadingState {
        case .unreachable:
            return "Cannot reach the Coder server."
        case .serverError(_, let statusCode):
            return "HTTP \(statusCode)"
        default:
            return nil
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

    private func populateDraft() {
        guard let existing else { return }
        draft = ConnectionDraft(
            connection: existing,
            keyLabel: model.keyLabel(forReference: existing.keyReference)
        )
        for index in draft.hops.indices {
            draft.hops[index].keyLabel =
                model.keyLabel(forReference: existing.jumpChain[index].keyReference) ?? ""
        }
    }

    private func prepareCoderModel() {
        Task {
            await coderModel.reloadServers()
            if draft.protocolID == "coder" {
                let serverID = draft.coderServerID.isEmpty ? nil : UUID(uuidString: draft.coderServerID)
                let workspaceID = draft.coderWorkspaceID.isEmpty ? nil : UUID(uuidString: draft.coderWorkspaceID)
                coderModel.prepareForInitialValues(serverID: serverID, workspaceID: workspaceID)
            }
        }
    }

    private func persist(connectAfterSave: Bool) {
        saveError = nil
        do {
            let connection = try draft.makeConnection()
            guard descriptor != nil else {
                saveError = "This protocol is unavailable in this build. Choose an available protocol before saving."
                return
            }
            isSaving = true
            Task {
                let result = await model.persist(connection)
                isSaving = false
                switch result {
                case .success:
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
}
