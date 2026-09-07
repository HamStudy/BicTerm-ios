import BicTermCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportKeySheet: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) var dismiss

    let keyStore: KeyStore

    enum IngestionState: Equatable {
        case empty
        case readyUnencrypted
        case needsPassphrase
        case rejected(String)
    }

    @State private var label = ""
    @State private var privateKeyData: Data?
    @State private var state: IngestionState = .empty
    @State private var passphrase = ""
    @State private var requiresBiometry = false
    @State private var errorMessage: String?
    @State private var isShowingFileImporter = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Name", text: $label)
                        .font(typography.body)
                        .accessibilityIdentifier("import-label")
                }

                Section {
                    Button {
                        ingest(UIPasteboard.general.dataForImport)
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("import-paste")
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Choose File…", systemImage: "folder")
                    }
                    .accessibilityIdentifier("import-file")
                    statusView
                        .font(typography.caption)
                        .foregroundColor(statusColor)
                        .accessibilityIdentifier("import-status")
                } header: {
                    Text("OpenSSH Private Key")
                } footer: {
                    Text("BicTerm imports OpenSSH ed25519 private keys only. The private key never leaves your keychain and is never shown on screen.")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }

                if state == .needsPassphrase {
                    Section("Passphrase") {
                        SecureField("Passphrase", text: $passphrase)
                            .font(typography.body)
                            .accessibilityIdentifier("import-passphrase")
                    }
                }

                Section {
                    Toggle("Require Biometrics", isOn: $requiresBiometry)
                        .font(typography.body)
                        .accessibilityIdentifier("import-biometrics")
                } footer: {
                    Text("Deleting or using this key will require Face ID or Touch ID.")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(typography.caption)
                            .foregroundColor(colors.error)
                            .accessibilityIdentifier("import-error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("import-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                    .accessibilityIdentifier("import-save")
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                ingest(FileManager.default.contents(atPath: url.path))
            }
        }
        .presentationDetents([.large])
    }

    private var canSave: Bool {
        label.trimmingCharacters(in: .whitespaces).isEmpty == false
            && privateKeyData != nil
            && (state == .readyUnencrypted || (state == .needsPassphrase && !passphrase.isEmpty))
    }

    private var statusColor: Color {
        switch state {
        case .empty: colors.dimmed
        case .readyUnencrypted, .needsPassphrase: colors.success
        case .rejected: colors.error
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .empty:
            Text("Paste or choose an OpenSSH private key file.")
        case .readyUnencrypted:
            Label("OpenSSH ed25519 key detected — unencrypted.", systemImage: "checkmark.circle")
        case .needsPassphrase:
            Label("Encrypted OpenSSH key detected — enter its passphrase.", systemImage: "lock")
        case .rejected(let message):
            Label(message, systemImage: "xmark.octagon")
        }
    }

    private func ingest(_ data: Data?) {
        guard let data, !data.isEmpty else {
            state = .rejected("The clipboard doesn't contain a private key.")
            return
        }
        privateKeyData = data
        passphrase = ""
        errorMessage = nil
        state = .empty
        Task {
            do {
                _ = try await OpenSSHPrivateKeyParser().parse(data, passphrase: nil)
                state = .readyUnencrypted
            } catch let error as OpenSSHPrivateKeyParserError {
                switch error {
                case .missingPassphrase:
                    state = .needsPassphrase
                case .unsupportedKeyType, .unsupportedCipher, .unsupportedKDF, .invalidFormat, .wrongPassphrase:
                    state = .rejected(KeyStoreError.from(error).message)
                }
            } catch {
                state = .rejected(KeyStoreError.from(error).message)
            }
        }
    }

    private func save() async {
        guard let data = privateKeyData else { return }
        isSaving = true
        defer { isSaving = false }
        if requiresBiometry {
            guard await keyStore.authorize(reason: "Authenticate to protect your imported SSH key") else {
                errorMessage = KeyStoreError.biometricGateDenied.message
                return
            }
        }
        do {
            _ = try await keyStore.importKey(
                data,
                passphrase: state == .needsPassphrase ? Data(passphrase.utf8) : nil,
                label: label.trimmingCharacters(in: .whitespaces),
                requiresBiometry: requiresBiometry
            )
            UIPasteboard.general.string = ""
            dismiss()
        } catch {
            errorMessage = (error as? KeyStoreError)?.message ?? KeyStoreError.actionFailed(String(describing: error)).message
        }
    }
}

private extension UIPasteboard {
    var dataForImport: Data? {
        if let string, !string.isEmpty { return Data(string.utf8) }
        if let data = data(forPasteboardType: UTType.data.identifier), !data.isEmpty { return data }
        return nil
    }
}
