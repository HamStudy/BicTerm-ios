#if HERDR_EMBED
import SwiftUI

/// Chrome for the embedded herdr TUI (plan herdr-embed T4): the native
/// workspace header composition — "Herdr — {label}", status line,
/// Disconnect — around ``HerdrTUIHostingView`` instead of the native pane
/// area. Herd entries present the same surface: the embedded client's own
/// machine sidebar owns multi-machine until T6 seeds the catalog.
///
/// Lifecycle: the view owns the process-single embedded instance while it
/// is on screen — appearing starts the client, disappearing stops it (the
/// embed shim allows one TUI per process; a herd re-open restarts it).
struct HerdrEmbedWorkspaceView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.colorScheme) private var colorScheme

    let endpointLabel: String
    let onClose: () -> Void
    var fontModel: TerminalFontModel? = nil

    @State private var runtime = HerdrEmbedRuntime.shared

    init(
        endpointLabel: String,
        onClose: @escaping () -> Void,
        fontModel: TerminalFontModel? = nil,
        runtime: HerdrEmbedRuntime = .shared
    ) {
        self.endpointLabel = endpointLabel
        self.onClose = onClose
        self.fontModel = fontModel
        _runtime = State(initialValue: runtime)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let footnote = ioFootnote {
                Text(footnote)
                    .font(typography.caption)
                    .foregroundStyle(colors.dimmed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, spacing.sm)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("herdr-embed-io")
                    .allowsHitTesting(false)
            }
        }
        .background(colors.background.ignoresSafeArea())
        // The embedded client owns the grid: the soft keyboard overlays
        // instead of compressing it (same contract as the native chrome).
        .ignoresSafeArea(.keyboard)
        .task {
            await runtime.startIfNeeded()
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            runtime.setHostAppearance(dark: scheme == .dark)
        }
        .onDisappear {
            Task { await runtime.requestStop() }
        }
    }

    private var phase: HerdrEmbedRuntime.Phase { runtime.phase }

    private var header: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text("Herdr — \(endpointLabel)")
                    .font(typography.headline)
                    .foregroundStyle(colors.foreground)
                    .accessibilityIdentifier("herdr-endpoint-label")
                Text(statusText)
                    .font(typography.caption)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("herdr-embed-status")
            }
            Spacer()
            if phase == .running {
                Button("Disconnect") {
                    Task { await runtime.requestStop() }
                }
                .font(typography.body)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("herdr-disconnect")
            }
        }
        .windowControlsClearance()
        .padding([.trailing, .top], spacing.sm)
        .padding(.bottom, spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .starting:
            VStack(spacing: spacing.sm) {
                ProgressView()
                Text("Connecting to Herdr")
                    .font(typography.body)
                    .foregroundStyle(colors.dimmed)
            }
            .accessibilityIdentifier("herdr-connecting")
        case .running:
            HerdrTUIHostingView(runtime: runtime, fontModel: fontModel)
        case let .failed(message):
            VStack(spacing: spacing.sm) {
                Text(message)
                    .font(typography.body)
                    .foregroundStyle(colors.foreground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, spacing.sm)
                    .accessibilityIdentifier("herdr-embed-failed")
                Button("Close", action: onClose)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("herdr-embed-close")
            }
        case .stopped:
            VStack(spacing: spacing.sm) {
                Text(disconnectText)
                    .font(typography.body)
                    .foregroundStyle(colors.foreground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, spacing.sm)
                Button("Close", action: onClose)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("herdr-embed-close")
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .idle, .starting: "connecting"
        case .running: "embedded client running"
        case .stopped: "disconnected"
        case .failed: "failed"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .idle, .starting: colors.dimmed
        case .running: colors.success
        case .stopped, .failed: colors.error
        }
    }

    private var disconnectText: String {
        if case let .stopped(exit) = phase, let exit {
            "The embedded herdr client ended (\(exit))."
        } else {
            "The embedded herdr client disconnected."
        }
    }

    #if DEBUG
    private var ioFootnote: String? {
        guard phase == .running else { return nil }
        return "embed io ↑\(runtime.bytesWritten) ↓\(runtime.bytesRead)"
    }
    #else
    private var ioFootnote: String? { nil }
    #endif
}
#endif
