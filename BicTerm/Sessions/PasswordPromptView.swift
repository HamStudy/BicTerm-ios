import BicTermCore
import SwiftUI

struct PasswordPromptView: View {
    @Environment(\.terminalColors) private var colors
    let request: SSHPasswordRequest
    let presenter: PasswordPromptPresenter
    @State private var password = ""
    @State private var remember = false
    @State private var submitting = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(request.username)@\(request.host):\(String(request.port))")
                        .textSelection(.enabled)
                    SecureField("Password", text: $password)
                        // Only this sheet's explicit toggle may offer to persist the password.
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("password-prompt-field")
                    if request.saveTag != nil {
                        Toggle("Save password in Keychain", isOn: $remember)
                            .accessibilityIdentifier("password-prompt-save")
                    }
                } header: {
                    Text("Server requests a password")
                } footer: {
                    Text(request.saveTag == nil
                         ? "This jump host password is used for this handshake only. To save a hop password, edit the connection."
                         : "Optional: save on this device only, protected when locked. Otherwise you'll be asked next time.")
                }
                if let sceneID = request.sceneID, let error = presenter.errors[sceneID] {
                    Text(error).foregroundStyle(colors.error)
                }
                Section {
                    Button("Connect") {
                        focused = false
                        submitting = true
                        Task {
                            await presenter.connect(request: request, password: password, remember: remember)
                            submitting = false
                        }
                    }
                    .disabled(submitting)
                    .accessibilityIdentifier("password-prompt-connect")
                    Button("Cancel") { presenter.cancel(request: request) }
                        .disabled(submitting)
                        .accessibilityIdentifier("password-prompt-cancel")
                }
            }
            .navigationTitle("SSH Password")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
        .accessibilityIdentifier("password-prompt")
        .interactiveDismissDisabled(submitting)
        .onDisappear { password = "" }
    }
}
