import BicTermCore
import SwiftUI

/// Lists keychain keys by label + SHA256 fingerprint ONLY — private key
/// material is never read, displayed, or accepted here.
///
/// The picker owns a live `KeyStore` (refresh() re-reads the Keychain), so
/// the list tracks generate/import/delete instead of freezing the snapshot
/// the editor happened to load; a fresh key saved inline is auto-selected
/// and returns the user straight to the editor.
struct KeyPickerView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyStore = KeyStore()
    @State private var showingGenerate = false
    @State private var showingImport = false
    @State private var knownReferences: Set<String> = []
    @State private var copyState: CopyState = .idle

    var selectedReference: String?
    let onSelect: (KeyMetadata) -> Void

    enum CopyState: Equatable {
        case idle
        case copied
        case failed
    }

    init(
        selectedReference: String? = nil,
        onSelect: @escaping (KeyMetadata) -> Void
    ) {
        self.selectedReference = selectedReference
        self.onSelect = onSelect
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
        .navigationTitle("Select Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .onAppear { keyStore.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // A picker left open in one iPad window re-reads the Keychain when
            // its scene reactivates, so keys mutated in another window or via
            // Key Management never leave this list stale.
            if phase == .active { keyStore.refresh() }
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
            ForEach(keyStore.keys) { item in
                keyRow(item)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func keyRow(_ item: KeyListItem) -> some View {
        let isSelected = item.metadata.reference == selectedReference
        return Button {
            onSelect(item.metadata)
            dismiss()
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
            }
            .frame(minHeight: 44)
        }
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
        keyStore.refresh()
        guard let added = keyStore.keys.first(where: { !previous.contains($0.id) }) else { return }
        onSelect(added.metadata)
        dismiss()
    }

    private func sanitized(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "-")
    }
}
