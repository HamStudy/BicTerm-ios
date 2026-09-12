import BicTermCore
import SwiftUI

/// TOFU host-key trust prompt, presented by the scene whose session hit the
/// typed `.requiresTrust` failure. Shows the exact host, port, algorithm,
/// and fingerprint; Trust persists via the production verifier and retries,
/// Cancel never trusts. Changed keys never reach this view.
struct HostTrustPromptView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let challenge: SessionStore.HostTrustChallenge
    let errorMessage: String?
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: spacing.md) {
                Label("Unknown Host Key", systemImage: "lock.shield")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .accessibilityIdentifier("trust-prompt")

                Text("You are connecting for the first time and this host's identity is not yet trusted. Verify the fingerprint through a channel you control before trusting it.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                VStack(alignment: .leading, spacing: spacing.xs) {
                    row(title: "Host", value: challenge.host, identifier: "trust-host")
                    row(title: "Port", value: String(challenge.port), identifier: "trust-port")
                    row(title: "Key Algorithm", value: challenge.algorithm, identifier: "trust-algorithm")
                    row(title: "Fingerprint (SHA256)", value: challenge.fingerprint, identifier: "trust-fingerprint")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(typography.caption)
                        .foregroundColor(colors.error)
                        .accessibilityIdentifier("trust-error")
                }

                Text("Trusting stores this key for future connections. If this key ever changes, BicTerm will refuse to connect.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                Spacer(minLength: 0)

                VStack(spacing: spacing.xs) {
                    Button {
                        onTrust()
                    } label: {
                        Text("Trust Host")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.accent)
                    .accessibilityIdentifier("trust-confirm")

                    Button(role: .cancel) {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.dimmed)
                    .accessibilityIdentifier("trust-cancel")
                }
            }
            .padding(spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Verify Host")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: spacing.xxxs) {
            Text(title)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Text(value)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
        .padding(spacing.xs)
        .background(colors.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
