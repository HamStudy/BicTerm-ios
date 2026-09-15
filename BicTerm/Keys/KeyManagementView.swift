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
                    ForEach(keyStore.keys) { item in
                        NavigationLink {
                            KeyDetailView(keyStore: keyStore, item: item)
                        } label: {
                            KeyRowView(item: item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(colors.background)
                        .accessibilityIdentifier("key-row-\(item.metadata.label)")
                        .accessibilityValue(item.metadata.enabledByDefault ? "Enabled" : "Disabled")
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
