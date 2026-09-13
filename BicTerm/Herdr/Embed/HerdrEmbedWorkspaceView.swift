#if HERDR_EMBED
import BicTermCore
import SwiftUI

/// Chrome for the embedded herdr TUI (plan herdr-embed T4): the native
/// workspace header composition — "Herdr — {label}", status line,
/// Disconnect — around ``HerdrTUIHostingView`` instead of the native pane
/// area. Herds present the same surface with the client's machine catalog
/// seeded per open (T6): each herd machine rides its own profile socket
/// through the bridge transport, and the REAL client's own sidebar owns
/// multi-machine selection/input/health.
///
/// Lifecycle: the view owns the process-single embedded instance while it
/// is on screen — appearing starts the client, disappearing stops it (the
/// embed shim allows one TUI per process). `ownerID` (the workspace entry
/// id) scopes that ownership: opening herd B closes herd A's run cleanly,
/// and herd A's surface renders a superseded state instead of mirroring
/// herd B's client.
///
/// T5: an `embedConnection` (Mode A) makes the runtime establish the SSH
/// bridge transport before the client boots; its TOFU challenge presents
/// here and transport failures render through the native diagnostic
/// taxonomy instead of a bare string.
struct HerdrEmbedWorkspaceView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.colorScheme) private var colorScheme

    let endpointLabel: String
    let onClose: () -> Void
    var fontModel: TerminalFontModel? = nil
    var embedConnection: Connection? = nil
    var embedHerd: HerdDescriptor? = nil
    var ownerID: UUID? = nil
    var hostKeyVerifier: HostKeyVerifier? = nil

    @State private var runtime = HerdrEmbedRuntime.shared

    init(
        endpointLabel: String,
        onClose: @escaping () -> Void,
        fontModel: TerminalFontModel? = nil,
        runtime: HerdrEmbedRuntime = .shared,
        embedConnection: Connection? = nil,
        embedHerd: HerdDescriptor? = nil,
        ownerID: UUID? = nil,
        hostKeyVerifier: HostKeyVerifier? = nil
    ) {
        self.endpointLabel = endpointLabel
        self.onClose = onClose
        self.fontModel = fontModel
        self.embedConnection = embedConnection
        self.embedHerd = embedHerd
        self.ownerID = ownerID
        self.hostKeyVerifier = hostKeyVerifier
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
            if let coordinator = await makeTransportCoordinator() {
                runtime.attachTransport(coordinator)
                trustCoordinator = coordinator
            }
            await runtime.startIfNeeded(ownerID: ownerID)
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            runtime.setHostAppearance(dark: scheme == .dark)
        }
        .onDisappear {
            Task { await runtime.requestStop(ownerID: ownerID) }
        }
        .modifier(EmbedTrustPromptPresenter(coordinator: trustCoordinator))
    }

    @State private var trustCoordinator: HerdrEmbedTransportCoordinator?

    private func makeTransportCoordinator() async -> HerdrEmbedTransportCoordinator? {
        if let embedHerd {
            let links = await HerdrEmbedHerdSeeder.links(for: embedHerd)
            guard !links.isEmpty else { return nil }
            return HerdrEmbedTransportCoordinator(
                machines: links,
                preferredSelection: embedHerd
                    .restoredSelection(defaults: .standard)
                    .map { HerdrEmbedMachine.profileID(for: $0.connectionID) },
                hostKeyVerifier: hostKeyVerifier
            )
        }
        if let embedConnection {
            return HerdrEmbedTransportCoordinator(
                connection: embedConnection,
                hostKeyVerifier: hostKeyVerifier
            )
        }
        return nil
    }

    private var phase: HerdrEmbedRuntime.Phase { runtime.phase }

    /// True when THIS surface's identity owns (or would own) the live run;
    /// a superseded surface must not host or stop another workspace's
    /// client. Nil owners (tests, legacy hosting) behave as owners.
    private var ownsLiveRun: Bool {
        runtime.currentOwner == nil || runtime.currentOwner == ownerID
    }

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
            if phase == .running, ownsLiveRun {
                Button("Disconnect") {
                    Task { await runtime.requestStop(ownerID: ownerID) }
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
        case .running where !ownsLiveRun:
            VStack(spacing: spacing.sm) {
                Image(systemName: "square.slash")
                    .font(typography.headline)
                    .foregroundStyle(colors.dimmed)
                Text("Another herdr workspace took over the embedded client. Close this window and reopen the herd to use it here.")
                    .font(typography.body)
                    .foregroundStyle(colors.dimmed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, spacing.sm)
                Button("Close", action: onClose)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("herdr-embed-close")
            }
            .accessibilityIdentifier("herdr-embed-superseded")
        case .running:
            HerdrTUIHostingView(runtime: runtime, fontModel: fontModel)
        case let .failed(message):
            VStack(spacing: spacing.sm) {
                if let diagnostic = runtime.failureDiagnostic {
                    Label(
                        diagnostic.title,
                        systemImage: diagnostic.kind == .authLost
                            ? "person.badge.key" : "wifi.exclamationmark"
                    )
                    .font(typography.headline)
                    .foregroundStyle(colors.error)
                }
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
        case .running where !ownsLiveRun: "superseded"
        case .running: "embedded client running"
        case .stopped: "disconnected"
        case .failed: "failed"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .idle, .starting: colors.dimmed
        case .running where !ownsLiveRun: colors.dimmed
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
        guard phase == .running, ownsLiveRun else { return nil }
        return "embed io ↑\(runtime.bytesWritten) ↓\(runtime.bytesRead)"
    }
    #else
    private var ioFootnote: String? { nil }
    #endif
}

/// Presents the embed transport's pending TOFU challenge above the
/// workspace (the carrier connects while this surface is already on
/// screen; a prompt attached to the covered connection list would never
/// surface). Mirrors ``HerdTrustPromptPresenter``.
private struct EmbedTrustPromptPresenter: ViewModifier {
    let coordinator: HerdrEmbedTransportCoordinator?

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { coordinator?.trustPrompt },
                set: { _ in }
            )
        ) { prompt in
            HostTrustPromptView(
                challenge: SessionStore.HostTrustChallenge(
                    host: prompt.challenge.host,
                    port: prompt.challenge.port,
                    algorithm: prompt.challenge.algorithm,
                    fingerprint: prompt.challenge.fingerprint,
                    publicKeyData: prompt.challenge.publicKeyData
                ),
                errorMessage: nil,
                onTrust: { coordinator?.resolveTrustPrompt(true) },
                onCancel: { coordinator?.resolveTrustPrompt(false) }
            )
            .interactiveDismissDisabled(true)
            .presentationDetents([.large])
            .terminalStyle()
        }
    }
}
#endif
