import BicTermCore
import SwiftUI

/// Missing-binary install consent (stage B): presented when a herdr
/// endpoint's probe found NO herdr binary on an otherwise-supported host.
/// Composes the same prompt surface pattern as ``HostTrustPromptView``
/// (fact rows + prominent confirm / bordered cancel) for install facts:
/// the host, the pinned release that would be installed, where it lands,
/// and the verified download source. Consent is per attempt — it is
/// never persisted, and there is no "always allow".
struct HerdrInstallConsentView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let consent: HerdrInstallConsent
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: spacing.md) {
                Label("Install herdr?", systemImage: "arrow.down.circle")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .accessibilityIdentifier("install-prompt")

                Text("No herdr executable was found on this host. BicTerm can install the pinned herdr release over this connection.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                VStack(alignment: .leading, spacing: spacing.xs) {
                    HostPromptFactRow(title: "Host", value: consent.host, identifier: "install-host")
                    HostPromptFactRow(title: "Version", value: "herdr \(consent.version)", identifier: "install-version")
                    HostPromptFactRow(title: "Destination", value: consent.destinationPath, identifier: "install-destination")
                    HostPromptFactRow(title: "Source", value: "herdr GitHub release, sha256-verified", identifier: "install-source")
                }

                Text("The binary is downloaded from the herdr GitHub release, checked against its committed sha256 pin, and copied to the host over this SSH connection. Nothing is elevated and nothing else on the host is changed.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                Text("You will be asked again on every connection that needs this.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                Spacer(minLength: 0)

                VStack(spacing: spacing.xs) {
                    Button {
                        onInstall()
                    } label: {
                        Text("Install herdr \(consent.version)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.accent)
                    .accessibilityIdentifier("install-confirm")

                    Button(role: .cancel) {
                        onCancel()
                    } label: {
                        Text("Not Now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.dimmed)
                    .accessibilityIdentifier("install-cancel")
                }
            }
            .padding(spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Install herdr")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
