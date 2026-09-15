import BicTermCore
import SwiftUI

/// Lists keychain keys by label + SHA256 fingerprint ONLY — private key
/// material is never read, displayed, or accepted here.
///
/// The shared observable store keeps membership live; nil selection follows
/// the resolver, while an explicit selection retains disabled memberships.
struct KeyPickerView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss
    @Environment(KeyStore.self) private var keyStore
    @Environment(KeyAvailabilityPreferences.self) private var preferences
    @State private var showingGenerate = false
    @State private var showingImport = false
    @State private var knownReferences: Set<String> = []
    @State private var copyState: CopyState = .idle

    @Binding var customKeys: [String]?

    enum CopyState: Equatable {
        case idle
        case copied
        case failed
    }

    private var inherited: [String] {
        KeyOfferResolver().resolve(
            KeyOfferRequest(offersKeys: true, customKeys: nil,
                            hardwareKeysEnabledByDefault: preferences.hardwareOfferedByDefault),
            keys: keyStore.keys.map(\.metadata)
        )
    }

    private var selected: Set<String> { Set(customKeys ?? inherited) }

    private func setSelection(_ references: Set<String>) {
        customKeys = references == Set(inherited) ? nil : references.sorted { lhs, rhs in
            let left = keyStore.keys.first { $0.id == lhs }?.metadata.label ?? ""
            let right = keyStore.keys.first { $0.id == rhs }?.metadata.label ?? ""
            let order = left.caseInsensitiveCompare(right)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if keyStore.keys.isEmpty {
                emptyState
            } else {
                keyList
            }
        }
        .background(colors.background)
        .navigationTitle("Customize Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("customize-done")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentSheet(.generate)
                    } label: {
                        Label("Generate Key", systemImage: "plus")
                    }
                    .accessibilityIdentifier("picker-menu-generate")
                    Button {
                        presentSheet(.import)
                    } label: {
                        Label("Import Key", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("picker-menu-import")
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(colors.accent)
                }
                .accessibilityLabel("Add Key")
                .accessibilityIdentifier("picker-add-menu")
            }
        }
        .sheet(isPresented: $showingGenerate, onDismiss: handleSheetDismiss) {
            GenerateKeySheet(keyStore: keyStore)
        }
        .sheet(isPresented: $showingImport, onDismiss: handleSheetDismiss) {
            ImportKeySheet(keyStore: keyStore)
        }
        .safeAreaInset(edge: .bottom) {
            copyConfirmationLabel
        }
    }

    private var emptyState: some View {
        VStack(spacing: spacing.lg) {
            ContentUnavailableView {
                Label("No Keys Yet", systemImage: "key")
            } description: {
                Text("Generate an ed25519 key or import an existing one — the new key is selected automatically.")
            }
            .accessibilityIdentifier("picker-empty-state")

            Button("Use All Enabled Keys") { customKeys = nil }
                .frame(minHeight: 44)
                .accessibilityIdentifier("use-all-enabled-keys")

            HStack(spacing: spacing.sm) {
                Button {
                    presentSheet(.generate)
                } label: {
                    Text("Generate Key")
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.accent)
                .accessibilityLabel("Generate Key")
                .accessibilityIdentifier("picker-empty-generate")
                Button {
                    presentSheet(.import)
                } label: {
                    Text("Import Key")
                }
                .buttonStyle(.bordered)
                .tint(colors.accent)
                .accessibilityLabel("Import Key")
                .accessibilityIdentifier("picker-empty-import")
            }
        }
    }

    private var keyList: some View {
        List {
            Section {
                Button("Use All Enabled Keys") { customKeys = nil }
                    .accessibilityIdentifier("use-all-enabled-keys")
                Text(customKeys == nil ? "Using inherited keys" : "Custom selection")
                    .accessibilityIdentifier("key-selection-mode")
            }
            ForEach(keyStore.keys) { item in
                keyRow(item)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func keyRow(_ item: KeyListItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            var references = selected
            if isSelected { references.remove(item.id) } else { references.insert(item.id) }
            setSelection(references)
        } label: {
            HStack(spacing: spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "key")
                    .foregroundColor(isSelected ? colors.success : colors.dimmed)
                VStack(alignment: .leading, spacing: spacing.xxxs) {
                    Text(item.metadata.label)
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    Text(item.metadata.fingerprint)
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                        .lineLimit(2)
                    Text(item.metadata.algorithm.rawValue + (item.metadata.requiresBiometry ? " · biometry" : ""))
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
                Spacer()
                if !item.metadata.enabledByDefault {
                    Text("Disabled")
                        .font(typography.caption)
                        .foregroundStyle(colors.dimmed)
                        .accessibilityIdentifier("disabled-key-badge")
                }
            }
            .frame(minHeight: 44)
        }
        .disabled(!item.metadata.enabledByDefault && !isSelected)
        .accessibilityIdentifier("key-\(sanitized(item.metadata.label))")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Long press to copy the public key")
        .contextMenu {
            Button {
                copyPublicKey(item)
            } label: {
                Label("Copy Public Key", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copy-key-\(sanitized(item.metadata.label))")
        }
    }

    /// Copy confirmation is app-observable state, verified by reading the
    /// pasteboard back inside the app (same pattern as KeyDetailView): the
    /// confirmation only appears when the pasteboard holds EXACTLY the
    /// authorized_keys line (public key only — never private bytes).
    private func copyPublicKey(_ item: KeyListItem) {
        let expected = item.authorizedKeysLine
        UIPasteboard.general.string = expected
        copyState = UIPasteboard.general.string == expected ? .copied : .failed
    }

    @ViewBuilder
    private var copyConfirmationLabel: some View {
        switch copyState {
        case .idle:
            EmptyView()
        case .copied:
            confirmationChip(
                "Copied public key",
                systemImage: "checkmark.circle.fill",
                color: colors.success
            )
        case .failed:
            confirmationChip(
                "Copy failed — try again",
                systemImage: "xmark.circle.fill",
                color: colors.error
            )
        }
    }

    private func confirmationChip(_ text: String, systemImage: String, color: Color) -> some View {
        TerminalBadge(text, systemImage: systemImage, tint: color, fill: colors.background, size: .regular)
            .padding(.bottom, spacing.xs)
            .accessibilityIdentifier("copy-confirmation")
    }

    private enum SheetKind {
        case generate
        case `import`
    }

    /// Snapshot references BEFORE the sheet opens; on dismiss, a reference
    /// that was not in the snapshot is the freshly saved key. References are
    /// per-key UUIDs, so the diff is unambiguous even for duplicate labels —
    /// and a cancelled sheet adds nothing, so no auto-select fires.
    private func presentSheet(_ kind: SheetKind) {
        knownReferences = Set(keyStore.keys.map(\.id))
        switch kind {
        case .generate: showingGenerate = true
        case .import: showingImport = true
        }
    }

    private func handleSheetDismiss() {
        let previous = knownReferences
        guard let added = keyStore.keys.first(where: { !previous.contains($0.id) }) else { return }
        setSelection(selected.union([added.id]))
        dismiss()
    }

    private func sanitized(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "-")
    }
}
