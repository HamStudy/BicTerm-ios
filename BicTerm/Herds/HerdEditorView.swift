import BicTermCore
import SwiftUI

/// Herd editor (herdr-support plan todo 7): name field plus a machine list
/// built exclusively from existing SSH connections. Machines are added via
/// a connection picker sheet and can only be REMOVED — the connection a
/// machine points at is never re-pointed (remove + re-add covers it).
/// Machines whose connection was deleted render a "Missing connection"
/// badge instead of connection details.
struct HerdEditorView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    let existing: Herd?
    let model: HerdsModel

    @State private var draft = HerdDraft()
    @State private var addMachinePresented = false
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                machinesSection
                saveSection
            }
            .navigationTitle(existing == nil ? "New Herd" : "Edit Herd")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-herd-editor")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-herd")
                }
            }
            .sheet(isPresented: $addMachinePresented) {
                AddHerdMachineSheet(candidates: candidateConnections) { connection in
                    addMachinePresented = false
                    draft.machines.append(HerdDraft.Machine(connectionID: connection.id))
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear(perform: populateDraft)
        }
        .terminalStyle()
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Herd Name", text: $draft.name)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("field-herd-name")
        } footer: {
            Text("A herd opens every machine's herdr workspace together behind one machine switcher.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
        }
    }

    private var machinesSection: some View {
        Section {
            ForEach(draft.machines) { machine in
                machineRow(machine)
            }

            Button {
                addMachinePresented = true
            } label: {
                Label("Add Machine", systemImage: "plus.circle")
            }
            .disabled(candidateConnections.isEmpty)
            .accessibilityIdentifier("add-herd-machine")
            .foregroundColor(colors.accent)
        } header: {
            Text("Machines (\(draft.machines.count))")
        } footer: {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text("Machines are existing SSH connections; each opens its own herdr endpoint when the herd opens. Remove and re-add to change which connection a machine uses.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .accessibilityIdentifier("herd-machines-footer")
                if let machineError {
                    Text(machineError)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("herd-machine-error")
                }
            }
        }
    }

    private var saveSection: some View {
        Section {
            if let saveError {
                Text(saveError)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .accessibilityIdentifier("herd-save-error")
            }
        }
    }

    // MARK: - Machine row

    private func machineRow(_ machine: HerdDraft.Machine) -> some View {
        let connection = model.connection(id: machine.connectionID)
        return VStack(alignment: .leading, spacing: spacing.xxs) {
            HStack(spacing: spacing.xs) {
                if let connection {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text(connection.name)
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                            .accessibilityIdentifier("herd-machine-name")
                        Text("\(connection.username)@\(connection.host):\(connection.port)")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Label("Missing connection", systemImage: "exclamationmark.triangle.fill")
                        .font(typography.caption)
                        .foregroundStyle(colors.error)
                        .accessibilityIdentifier("herd-machine-missing")
                }
                Spacer()
            }

            TextField("Remote Session (optional)", text: machineSessionBinding(machine))
                .font(typography.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(
                    "herd-machine-session-\(machineRowKey(machine.connectionID))"
                )
        }
        .padding(.vertical, spacing.xxxs)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removeMachine(machine)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityIdentifier("remove-herd-machine-\(machineRowKey(machine.connectionID))")
        }
    }

    /// Stable row key: the connection id prefixed so it never collides with
    /// other identifiers, trimmed to a readable length.
    private func machineRowKey(_ connectionID: UUID) -> String {
        String(connectionID.uuidString.prefix(8))
    }

    private func machineSessionBinding(_ machine: HerdDraft.Machine) -> Binding<String> {
        Binding(
            get: {
                draft.machines.first { $0.id == machine.id }?.sessionName ?? ""
            },
            set: { value in
                if let index = draft.machines.firstIndex(where: { $0.id == machine.id }) {
                    draft.machines[index].sessionName = value
                }
            }
        )
    }

    private func removeMachine(_ machine: HerdDraft.Machine) {
        draft.machines.removeAll { $0.id == machine.id }
    }

    // MARK: - Validation + save

    private var candidateConnections: [Connection] {
        let taken = Set(draft.machines.map(\.connectionID))
        return model.connections
            .filter { $0.type == .ssh && !taken.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var machineError: String? {
        for machine in draft.machines {
            let session = machine.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty else { continue }
            if session.contains(where: { $0.isNewline }) {
                return "Remote Session names can't contain line breaks."
            }
            if session.count > HerdMachine.maximumSessionNameLength {
                return "Remote Session names are limited to \(HerdMachine.maximumSessionNameLength) characters."
            }
        }
        return nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && machineError == nil && !isSaving
    }

    private func populateDraft() {
        guard let existing, !draft.isPopulated else { return }
        draft = HerdDraft(from: existing)
    }

    private func save() {
        isSaving = true
        saveError = nil
        let machines = draft.machines.map { machine in
            try? HerdMachine(
                connectionID: machine.connectionID,
                sessionName: machine.sessionName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let herd = try? Herd(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            machines: machines.compactMap { $0 }
        ) else {
            isSaving = false
            saveError = "The herd couldn't be saved. Check the name and machines."
            return
        }
        Task {
            let result = await model.persist(herd)
            isSaving = false
            switch result {
            case .success:
                dismiss()
            case .failure:
                saveError = "The herd couldn't be saved. Try again."
            }
        }
    }
}

// MARK: - Draft

struct HerdDraft {
    struct Machine: Identifiable {
        let id = UUID()
        let connectionID: UUID
        var sessionName = ""
    }

    var name = ""
    var machines: [Machine] = []
    var isPopulated = false

    init() {}

    init(from herd: Herd) {
        name = herd.name
        machines = herd.machines.map { machine in
            Machine(connectionID: machine.connectionID, sessionName: machine.sessionName ?? "")
        }
        isPopulated = true
    }
}

// MARK: - Add Machine sheet

/// Picker over the herd's candidate SSH connections: every connection not
/// already used by another machine of this herd.
private struct AddHerdMachineSheet: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    let candidates: [Connection]
    let onPick: (Connection) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    Text("Every SSH connection is already in this herd.")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                        .padding(spacing.sm)
                        .accessibilityIdentifier("herd-add-machine-empty")
                } else {
                    List(candidates) { connection in
                        Button {
                            onPick(connection)
                        } label: {
                            VStack(alignment: .leading, spacing: spacing.xxxs) {
                                Text(connection.name)
                                    .font(typography.body)
                                    .foregroundColor(colors.foreground)
                                Text("\(connection.username)@\(connection.host):\(connection.port)")
                                    .font(typography.caption)
                                    .foregroundColor(colors.dimmed)
                            }
                        }
                        .accessibilityIdentifier(
                            "herd-candidate-\(connection.name.replacingOccurrences(of: " ", with: "-"))"
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Add Machine")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-add-herd-machine")
                }
            }
        }
        .terminalStyle()
    }
}
