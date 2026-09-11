import BicTermCore
import SwiftUI

/// Preflight-probe diagnostic screen (integration doc §6.1/§11): shown when
/// the preflight probe found no herdr or an incompatible one — BEFORE any
/// bridge channel opens. Reports the host, detected platform, the path and
/// version found (if any), the endpoint generation this app requires, and
/// a link to the official documentation. It never offers or executes an
/// installation command — Herdr is maintained on the host, outside the app.
struct HerdrProbeDiagnosticView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let probe: HerdrProbe.Result
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing.md) {
                Label(probeTitle, systemImage: "exclamationmark.shield.fill")
                    .font(typography.headline)
                    .foregroundStyle(colors.error)
                    .accessibilityIdentifier("herdr-probe-title")

                Text(probe.host)
                    .font(typography.caption)
                    .foregroundStyle(colors.dimmed)
                    .accessibilityIdentifier("herdr-probe-host")

                VStack(alignment: .leading, spacing: spacing.xs) {
                    row("Host platform", platformLabel)
                        .accessibilityIdentifier("herdr-probe-platform")
                    row("Herdr found", probe.foundPath ?? "not found")
                        .accessibilityIdentifier("herdr-probe-path")
                    row("Herdr version", probe.version ?? "unknown")
                        .accessibilityIdentifier("herdr-probe-version")
                    row("Endpoint generation required", "generation \(HerdrProbe.Result.requiredGeneration)")
                        .accessibilityIdentifier("herdr-probe-generation")
                    if let found = probe.endpointGeneration {
                        row("Endpoint generation reported", "generation \(found)")
                            .accessibilityIdentifier("herdr-probe-reported-generation")
                    }
                }
                .padding(spacing.sm)
                .background(colors.selection.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: spacing.xxs) {
                    if let docs = HerdrDiagnostic.remediationURL {
                        Link(
                            "Herdr installation and upgrade documentation",
                            destination: docs
                        )
                        .font(typography.body)
                        .foregroundStyle(colors.accent)
                        .accessibilityIdentifier("herdr-probe-remediation")
                    }

                    Text("A compatible Herdr must already be installed and maintained on the host. This app never installs, updates, or upgrades Herdr; after the host is prepared outside the app, try connecting again.")
                        .font(typography.caption)
                        .foregroundStyle(colors.dimmed)
                        .accessibilityIdentifier("herdr-probe-boundary-note")
                }

                Button("Close", action: onDismiss)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("herdr-probe-dismiss")
            }
            .padding(spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.background.ignoresSafeArea())
        .accessibilityIdentifier("herdr-probe-diagnostic")
    }

    private var probeTitle: String {
        probe.foundPath == nil
            ? "No Herdr found on the host"
            : "Incompatible Herdr on the host"
    }

    private var platformLabel: String {
        let raw = [probe.rawOS, probe.rawArch].compactMap(\.self).joined(separator: " ")
        guard let os = probe.platformOS, let arch = probe.platformArch else {
            return raw.isEmpty ? "unknown \(probe.host)" : "\(raw) (unsupported)"
        }
        return "\(os) \(arch)"
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
