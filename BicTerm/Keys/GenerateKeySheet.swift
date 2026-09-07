import BicTermCore
import SwiftUI

struct GenerateKeySheet: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) var dismiss

    let keyStore: KeyStore

    @State private var label = ""
    @State private var type: KeyType = .ed25519
    @State private var requiresBiometry = true
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Name", text: $label)
                        .font(typography.body)
                        .accessibilityIdentifier("generate-label")
                    Picker("Type", selection: $type) {
                        ForEach(KeyType.allCases) { candidate in
                            Text(candidate.displayName)
                                .tag(candidate)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: type) { _, newValue in
                        if !newValue.isAvailable { type = .ed25519 }
                    }
                    .accessibilityIdentifier("generate-type")
                    .foregroundColor(colors.foreground)
                }
                Section {
                    Toggle("Require Biometrics", isOn: $requiresBiometry)
                        .font(typography.body)
                        .accessibilityIdentifier("generate-biometrics")
                } footer: {
                    Text("Deleting or using this key will require Face ID or Touch ID.")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                }
                if !KeyType.secureEnclaveP256.isAvailable {
                    Section {
                        Label(
                            "Secure Enclave keys need a device with a Secure Enclave. The simulator cannot store them.",
                            systemImage: "lock.shield"
                        )
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(typography.caption)
                            .foregroundColor(colors.error)
                            .accessibilityIdentifier("generate-error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .navigationTitle("Generate Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("generate-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        Task { await save() }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .accessibilityIdentifier("generate-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard type.isAvailable else {
            errorMessage = KeyStoreError.secureEnclaveUnavailable.message
            return
        }
        if requiresBiometry {
            guard await keyStore.authorize(reason: "Authenticate to protect your new SSH key") else {
                errorMessage = KeyStoreError.biometricGateDenied.message
                return
            }
        }
        do {
            _ = try await keyStore.generate(
                label: label.trimmingCharacters(in: .whitespaces),
                type: type,
                requiresBiometry: requiresBiometry
            )
            dismiss()
        } catch {
            errorMessage = (error as? KeyStoreError)?.message ?? KeyStoreError.actionFailed(String(describing: error)).message
        }
    }
}
