import SwiftUI
import UIKit

// MARK: - Open policy

/// Whether a terminal-emitted link may be opened, plus the host to show
/// the user. ONLY valid http/https URLs are openable — `file:`, `ssh:`,
/// other schemes, relative text, and unparseable strings present with
/// Open disabled. The system opener runs exclusively after the user
/// confirms on the sheet.
struct TerminalLinkDecision: Equatable, Sendable {
    let canOpen: Bool
    let host: String?
}

enum TerminalLinkPolicy {
    static func evaluate(_ link: String) -> TerminalLinkDecision {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return TerminalLinkDecision(canOpen: false, host: nil)
        }
        return TerminalLinkDecision(canOpen: true, host: host)
    }
}

// MARK: - Request

/// One immutable link-open request surfaced by a terminal tap (explicit
/// OSC 8 or implicit detection, activated by finger/Pencil through fork
/// hunk 13 or a hover-gated pointer click). Value semantics: the params
/// dictionary is captured by value, and each request carries a fresh
/// identity so dismissing and re-tapping the same link re-presents.
struct TerminalLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let link: String
    let params: [String: String]

    init(link: String, params: [String: String]) {
        self.id = UUID()
        self.link = link
        self.params = params
    }
}

// MARK: - Confirmation sheet

/// Host-visible confirmation for one link request: the destination host
/// is prominent, the FULL URL is shown (wrapping, never truncated),
/// Open is enabled only for policy-approved http(s) links, and Cancel
/// (or swipe-down) sends nothing. The system opener runs only through
/// the scene model's confirmed path.
struct TerminalLinkConfirmationSheet: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let request: TerminalLinkRequest
    let onOpen: () -> Void
    let onCancel: () -> Void

    private var decision: TerminalLinkDecision {
        TerminalLinkPolicy.evaluate(request.link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.sm) {
            HStack(spacing: spacing.xs) {
                Image(systemName: "link")
                    .font(typography.headline)
                    .foregroundColor(colors.accent)
                Text("Open Link?")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
            }
            if let host = decision.host {
                Text(host)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("link-confirm-host")
            }
            Text(request.link)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link-confirm-url")
            if !decision.canOpen {
                Text("Only http and https links can be opened.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
            HStack(spacing: spacing.sm) {
                Spacer()
                Button("Cancel") { onCancel() }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("link-confirm-cancel")
                Button("Open") { onOpen() }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.accent)
                    .disabled(!decision.canOpen)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("link-confirm-open")
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-confirmation-sheet")
    }
}
