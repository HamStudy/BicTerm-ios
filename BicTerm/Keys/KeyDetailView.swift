import BicTermCore
import SwiftUI

struct KeyDetailView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) var dismiss

    let keyStore: KeyStore
    let item: KeyListItem

    @State private var showingDeleteConfirmation = false
    @State private var referencingConnections: [Connection] = []
    @State private var errorMessage: String?
    @State private var copyState: CopyState = .idle

    enum CopyState: Equatable {
        case idle
        case copied
        case failed
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: spacing.xs) {
                    HStack(spacing: spacing.xs) {
                        Text(item.metadata.label)
                            .font(typography.headline)
                            .foregroundColor(colors.foreground)
                        KeyTypeBadge(item: item)
                        if item.metadata.requiresBiometry {
                            Image(systemName: "faceid")
                                .font(typography.caption)
                                .foregroundColor(colors.accent)
                        }
                    }
                    LabeledContent {
                        Text(item.metadata.fingerprint)
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    } label: {
                        Text("Fingerprint")
                    }
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    if let created = item.createdDate {
                        LabeledContent {
                            Text(created.formatted(date: .abbreviated, time: .omitted))
                                .foregroundColor(colors.dimmed)
                        } label: {
                            Text("Created")
                        }
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    }
                    LabeledContent {
                        Text(item.metadata.requiresBiometry ? "Required" : "Off")
                            .foregroundColor(colors.dimmed)
                    } label: {
                        Text("Biometric Gate")
                    }
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                }
                .listRowBackground(colors.background)
            }

            Section("Public Key") {
                VStack(alignment: .leading, spacing: spacing.xs) {
                    Text(item.authorizedKeysLine)
                        .font(typography.caption)
                        .foregroundColor(colors.foreground)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("public-key-text")
                    HStack(spacing: spacing.sm) {
                        Button {
                            copyPublicKey()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(typography.caption)
                                .foregroundColor(colors.accent)
                                .padding(.horizontal, spacing.sm)
                                .padding(.vertical, spacing.xs)
                                .background(colors.accent.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("copy-public-key")
                        copyConfirmationLabel
                        ShareLink(item: item.authorizedKeysLine) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(typography.caption)
                                .foregroundColor(colors.accent)
                                .padding(.horizontal, spacing.sm)
                                .padding(.vertical, spacing.xs)
                                .background(colors.accent.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("share-public-key")
                    }
                    .buttonStyle(.borderless)
                }
                .listRowBackground(colors.background)
            }

            Section {
                Button("Delete Key", role: .destructive) {
                    Task {
                        referencingConnections = await keyStore.connectionsReferencing(item)
                        showingDeleteConfirmation = true
                    }
                }
                .foregroundColor(colors.error)
                .accessibilityIdentifier("delete-key")
                if let errorMessage {
                    Text(errorMessage)
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("key-detail-error")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Key Details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete “\(item.metadata.label)”?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Key", role: .destructive) {
                Task { await performDelete() }
            }
            .accessibilityIdentifier("confirm-delete-key")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteWarningMessage)
                .accessibilityIdentifier("delete-warning")
        }
    }

    /// Copy confirmation is app-observable state, verified by reading the
    /// pasteboard back inside the app: the confirmation only appears when the
    /// pasteboard holds EXACTLY the authorized_keys line (public key only —
    /// never private bytes). UI tests assert this state instead of polling
    /// `UIPasteboard` from the test runner.
    private func copyPublicKey() {
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
            Label("Copied public key", systemImage: "checkmark.circle.fill")
                .font(typography.caption)
                .foregroundColor(colors.success)
                .accessibilityIdentifier("copy-confirmation")
        case .failed:
            Label("Copy failed — try again", systemImage: "xmark.circle.fill")
                .font(typography.caption)
                .foregroundColor(colors.error)
                .accessibilityIdentifier("copy-confirmation")
        }
    }

    private var deleteWarningMessage: String {
        if referencingConnections.isEmpty {
            return "This key is not used by any connection. Connections cannot authenticate with it after deletion. This cannot be undone."
        }
        let names = referencingConnections.map(\.name).joined(separator: ", ")
        return "Used by: \(names). These connections will no longer be able to authenticate with this key. This cannot be undone."
    }

    private func performDelete() async {
        guard await keyStore.authorize(reason: "Authenticate to delete your SSH key") else {
            errorMessage = KeyStoreError.biometricGateDenied.message
            return
        }
        do {
            try keyStore.delete(item)
            keyStore.refresh()
            dismiss()
        } catch {
            errorMessage = (error as? KeyStoreError)?.message ?? KeyStoreError.actionFailed(String(describing: error)).message
        }
    }
}
