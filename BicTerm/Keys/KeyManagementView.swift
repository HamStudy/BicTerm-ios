import BicTermCore
import SwiftUI

struct KeyManagementView: View {
    @Environment(KeyStore.self) private var keyStore
    @State private var showingGenerate = false
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            KeyListView(
                keyStore: keyStore,
                showingGenerate: $showingGenerate,
                showingImport: $showingImport
            )
        }
        .task {
            #if DEBUG
            UITestSupport.activate()
            #endif
            #if DEBUG
            UITestSupport.seedConnectionIfNeeded()
            #endif
        }
        .sheet(isPresented: $showingGenerate) {
            GenerateKeySheet(keyStore: keyStore)
        }
        .sheet(isPresented: $showingImport) {
            ImportKeySheet(keyStore: keyStore)
        }
    }
}

struct KeyListView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) var dismiss

    let keyStore: KeyStore
    @Binding var showingGenerate: Bool
    @Binding var showingImport: Bool

    var body: some View {
        Group {
            if keyStore.keys.isEmpty {
                ContentUnavailableView {
                    Label("No Keys Yet", systemImage: "key")
                } description: {
                    Text("Generate an ed25519 key or import an existing one to authenticate your SSH connections.")
                }
                .accessibilityIdentifier("key-empty-state")
            } else {
                List {
                    if keyStore.enabledCount > 5 {
                        Text("\(keyStore.enabledCount) keys are enabled. Many servers allow only 6 authentication attempts and may disconnect before later keys are tried.")
                            .font(typography.caption)
                            .foregroundStyle(colors.dimmed)
                            .accessibilityIdentifier("enabled-count-banner")
                            .listRowBackground(colors.background)
                    }
                    ForEach(keyStore.keys) { item in
                        KeyToggleRow(keyStore: keyStore, item: item)
                        .listRowBackground(colors.background)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(colors.background)
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
                    .foregroundColor(colors.accent)
                    .accessibilityIdentifier("keys-done")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingGenerate = true
                    } label: {
                        Label("Generate Key", systemImage: "plus")
                    }
                    .accessibilityIdentifier("menu-generate")
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import Key", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("menu-import")
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(colors.accent)
                }
                .accessibilityLabel("Add Key")
                .accessibilityIdentifier("keys-add-menu")
            }
        }
    }
}

private struct KeyToggleRow: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography

    let keyStore: KeyStore
    let item: KeyListItem

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                NavigationLink {
                    KeyDetailView(keyStore: keyStore, item: item)
                } label: {
                    KeyRowView(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("key-row-\(item.metadata.label)")
                .accessibilityValue(item.metadata.enabledByDefault ? "Enabled" : "Disabled")

                Toggle("Enabled", isOn: Binding(
                    get: { item.metadata.enabledByDefault },
                    set: { enabled in
                        Task { await setEnabled(enabled) }
                    }
                ))
                .labelsHidden()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Enable \(item.metadata.label)")
                .tint(colors.accent)
                .accessibilityIdentifier("key-enabled-toggle-\(item.metadata.reference)")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .accessibilityIdentifier("key-toggle-error")
            }
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        let priorState = item.metadata.enabledByDefault
        guard enabled != priorState else { return }
        errorMessage = nil
        do {
            try await keyStore.setEnabled(enabled, item: item)
        } catch {
            keyStore.refresh()
            errorMessage = (error as? KeyStoreError)?.message
                ?? KeyStoreError.actionFailed(String(describing: error)).message
        }
    }
}

struct KeyRowView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    let item: KeyListItem

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xxs) {
            HStack(spacing: spacing.xs) {
                Text(item.metadata.label)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                KeyTypeBadge(item: item)
                if item.metadata.requiresBiometry {
                    Image(systemName: "faceid")
                        .font(typography.caption)
                        .foregroundColor(colors.accent)
                        .accessibilityLabel("Biometric gate")
                        .accessibilityIdentifier("key-biometric-badge")
                }
                Spacer()
            }
            Text(item.metadata.fingerprint)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .lineLimit(2)
                .accessibilityIdentifier("key-fingerprint")
            if let created = item.createdDate {
                Text("Created \(created.formatted(date: .abbreviated, time: .omitted))")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .accessibilityIdentifier("key-created")
            }
        }
        .padding(.vertical, spacing.xxs)
    }
}

struct KeyTypeBadge: View {
    @Environment(\.terminalColors) var colors

    let item: KeyListItem

    var body: some View {
        TerminalBadge(
            item.typeBadge,
            tint: item.isSecureEnclave ? colors.success : colors.accent,
            shape: .rounded
        )
        .accessibilityIdentifier("key-type-badge")
    }
}
