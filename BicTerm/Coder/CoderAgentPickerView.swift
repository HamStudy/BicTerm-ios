import BicTermCore
import SwiftUI

/// Explicit agent chooser for workspaces exposing multiple agents (spec
/// §5.2): ambiguity is surfaced to the user, never auto-picked. Pushed by
/// the connection editor; lists the latest build's connected agents and
/// reports the choice back before popping.
struct CoderAgentPickerView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dismiss) private var dismiss

    let workspaceName: String
    let agents: [CoderWorkspaceAgent]
    let selectedAgentID: UUID?
    let onSelect: (CoderWorkspaceAgent) -> Void

    private var sortedAgents: [CoderWorkspaceAgent] {
        agents.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedAgents) { agent in
                    Button {
                        onSelect(agent)
                        dismiss()
                    } label: {
                        agentRow(agent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("coder-agent-\(sanitized(agent.name))")
                }
            } header: {
                Text("Connected agents in \(workspaceName)")
            } footer: {
                Text("This workspace exposes multiple connected agents. BicTerm never picks one automatically — choose the agent this connection should use.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Select Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("coder-agent-picker-cancel")
            }
        }
    }

    private func agentRow(_ agent: CoderWorkspaceAgent) -> some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(agent.name)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                Text(agent.id.uuidString)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if agent.id == selectedAgentID {
                Image(systemName: "checkmark")
                    .foregroundColor(colors.accent)
            }
        }
        .padding(.vertical, spacing.xxs)
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}

#Preview("Two Agents") {
    let json = #"[{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connected"},{"id":"55555555-5555-4555-8555-555555555555","name":"sidecar","status":"connected"}]"#
    let agents = (try? JSONDecoder().decode([CoderWorkspaceAgent].self, from: Data(json.utf8))) ?? []
    return NavigationStack {
        CoderAgentPickerView(
            workspaceName: "Running Dev",
            agents: agents,
            selectedAgentID: nil,
            onSelect: { _ in }
        )
    }
    .terminalStyle()
}
