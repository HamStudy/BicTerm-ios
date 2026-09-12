import BicTermCore
import SwiftUI

/// In-window session switcher: lists every live session (connection name,
/// state badge, unread dot for detached sessions with new output), attaches
/// the tapped row in the presenting context, closes rows through the
/// existing confirmation guard, and routes to the connection list for new
/// connections. Sessions are NEVER closed by switching away.
struct SessionSwitcherView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dismiss) private var dismiss

    let store: SessionStore
    /// The session currently attached in the presenting context (marked
    /// "Current"); nil when presented from the connection list.
    let currentSessionID: UUID?
    let onPick: (UUID) -> Void
    let onNewConnection: () -> Void

    private struct Row: Identifiable {
        let descriptor: SessionStore.SessionDescriptor
        let key: String

        var id: UUID { descriptor.id }
    }

    private var rows: [Row] {
        var counts: [String: Int] = [:]
        return store.orderedDescriptors.map { descriptor in
            let base = sanitized(descriptor.connection.name)
            counts[base, default: 0] += 1
            return Row(descriptor: descriptor, key: "\(base)-\(counts[base] ?? 1)")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onNewConnection()
                    } label: {
                        Label("New connection…", systemImage: "plus.circle")
                            .foregroundColor(colors.accent)
                    }
                    .accessibilityIdentifier("switcher-new-connection")
                    .listRowBackground(colors.background)
                }

                Section {
                    ForEach(rows) { row in
                        SessionSwitcherRow(
                            descriptor: row.descriptor,
                            key: row.key,
                            store: store,
                            isCurrent: row.descriptor.id == currentSessionID,
                            onPick: onPick
                        )
                        .listRowBackground(colors.background)
                    }
                } header: {
                    Text("Live Sessions")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("switcher-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { store.warmSceneModelsForSwitcher() }
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}

private struct SessionSwitcherRow: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let descriptor: SessionStore.SessionDescriptor
    let key: String
    let store: SessionStore
    let isCurrent: Bool
    let onPick: (UUID) -> Void

    @State private var hasUnseenOutput = false

    var body: some View {
        HStack(spacing: spacing.sm) {
            if hasUnseenOutput {
                Text("●")
                    .font(.system(size: 12))
                    .foregroundColor(colors.accent)
                    .accessibilityLabel("Unread activity")
                    .accessibilityIdentifier("switcher-unread-\(key)")
            }

            Button {
                onPick(descriptor.id)
            } label: {
                HStack(spacing: spacing.sm) {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text(descriptor.connection.name)
                            .font(typography.headline)
                            .foregroundColor(colors.foreground)
                            .accessibilityIdentifier("switcher-name-\(key)")
                        Text(stateBadgeText)
                            .font(typography.caption)
                            .foregroundColor(stateBadgeColor)
                            .accessibilityIdentifier("switcher-state-\(key)")
                    }

                    Spacer()

                    if isCurrent {
                        Text("Current")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .accessibilityIdentifier("switcher-current-\(key)")
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                store.existingModel(for: descriptor.id)?.requestClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(colors.dimmed)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Close session")
            .accessibilityIdentifier("switcher-close-\(key)")
        }
        .confirmationDialog(
            "Disconnect from \(descriptor.connection.name)?",
            isPresented: closeConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                store.existingModel(for: descriptor.id)?.confirmClose()
            }
            .accessibilityIdentifier("switcher-confirm-close")
            Button("Cancel", role: .cancel) {
                store.existingModel(for: descriptor.id)?.cancelClose()
            }
            .accessibilityIdentifier("switcher-cancel-close")
        } message: {
            Text("The remote session will be terminated.")
        }
        .task { await pollUnseenOutput() }
    }

    private var model: SessionSceneModel? {
        store.existingModel(for: descriptor.id)
    }

    private var stateBadgeText: String {
        switch model?.state {
        case .active: "connected"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .suspended: "reconnect required"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed, .none: "ended"
        }
    }

    private var stateBadgeColor: Color {
        switch model?.state {
        case .active: colors.success
        case .connecting, .reconnecting: colors.accent
        case .failed: colors.error
        default: colors.dimmed
        }
    }

    private var closeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model?.pendingCloseConfirmation ?? false },
            set: { presented in
                if !presented { model?.cancelClose() }
            }
        )
    }

    /// The unread dot is registry-owned actor state (not observable) —
    /// poll it while the row is on screen.
    private func pollUnseenOutput() async {
        let sceneID = descriptor.registrySceneID
        while !Task.isCancelled {
            if let presentation = await store.registry.presentationState(sceneID: sceneID) {
                hasUnseenOutput = presentation.hasUnseenOutput
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
