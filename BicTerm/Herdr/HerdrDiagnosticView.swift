import SwiftUI

/// Version-gate / connection-end screen (integration doc §4/§6.3): reports
/// the local protocol-core version, the endpoint generation this app
/// implements, the typed failure detail, and — for compatibility failures —
/// a remediation link. Taxonomy kinds whose remote workspace survives offer
/// an explicit re-attach (fresh hello, authoritative state). No
/// private-protocol fallback is ever offered.
struct HerdrDiagnosticView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let diagnostic: HerdrDiagnostic
    let endpointLabel: String
    var onReattach: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing.md) {
                Label(diagnostic.title, systemImage: iconName)
                    .font(typography.headline)
                    .foregroundStyle(diagnostic.remediationRequired ? colors.error : colors.dimmed)
                    .accessibilityIdentifier("herdr-diagnostic-title")

                Text(endpointLabel)
                    .font(typography.caption)
                    .foregroundStyle(colors.dimmed)
                    .accessibilityIdentifier("herdr-diagnostic-endpoint")

                VStack(alignment: .leading, spacing: spacing.xs) {
                    row("This app's Herdr core", diagnostic.localCoreVersion)
                        .accessibilityIdentifier("herdr-diagnostic-local-version")
                    row("Endpoint generation supported", "generation \(diagnostic.expectedGeneration)")
                        .accessibilityIdentifier("herdr-diagnostic-generation")
                    if diagnostic.remediationRequired {
                        row("Remote server", "incompatible — handshake rejected")
                            .accessibilityIdentifier("herdr-diagnostic-remote")
                    }
                }
                .padding(spacing.sm)
                .background(colors.selection.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                if !diagnostic.detail.isEmpty {
                    Text(diagnostic.detail)
                        .font(typography.caption)
                        .foregroundStyle(colors.dimmed)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("herdr-diagnostic-detail")
                }

                if diagnostic.remediationRequired {
                    VStack(alignment: .leading, spacing: spacing.xxs) {
                        if let url = diagnostic.remediationURL {
                            Link("Herdr installation and upgrade documentation", destination: url)
                                .font(typography.body)
                                .foregroundStyle(colors.accent)
                                .accessibilityIdentifier("herdr-diagnostic-remediation")
                        }
                        Text("The connection was closed. Herdr is maintained on the host; this app never installs or updates it.")
                            .font(typography.caption)
                            .foregroundStyle(colors.dimmed)
                            .accessibilityIdentifier("herdr-diagnostic-boundary-note")
                    }
                }

                if let onReattach {
                    Button("Re-attach", action: onReattach)
                        .font(typography.body)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("herdr-reattach")
                    Text("The workspace keeps running on the host. Re-attaching connects with a fresh hello and shows the server's current state.")
                        .font(typography.caption)
                        .foregroundStyle(colors.dimmed)
                        .accessibilityIdentifier("herdr-reattach-note")
                }

                Button("Close", action: onDismiss)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("herdr-diagnostic-dismiss")
            }
            .padding(spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.background.ignoresSafeArea())
        .accessibilityIdentifier("herdr-diagnostic")
    }

    private var iconName: String {
        switch diagnostic.kind {
        case .incompatibleGeneration, .handshakeRejected: "exclamationmark.shield.fill"
        case .handshakeTimedOut: "clock.badge.exclamationmark"
        case .protocolViolation: "bolt.horizontal.circle"
        case .transportLost: "wifi.exclamationmark"
        case .remoteClosed: "checkmark.circle"
        case .userDetach: "arrow.down.right.and.arrow.up.left"
        case .serverShutdown: "powerplug"
        case .authLost: "person.badge.key"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: spacing.sm)
            Text(value)
        }
        .font(typography.caption)
        .foregroundStyle(colors.foreground)
        .accessibilityElement(children: .combine)
    }
}
