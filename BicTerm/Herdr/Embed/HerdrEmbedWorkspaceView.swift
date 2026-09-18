import BicTermCore
import SwiftUI

/// Chrome for the embedded herdr TUI (plan herdr-embed T4): the workspace
/// presents the SAME top chrome as a terminal session — ``HerdrChromeView``
/// (title, Herdr badge, live status chip, session menu, Close) — around
/// ``HerdrTUIHostingView`` instead of the native pane area. Herds present
/// the same surface with the client's machine catalog seeded per open (T6):
/// each herd machine rides its own profile socket through the bridge
/// transport, and the REAL client's own sidebar owns multi-machine
/// selection/input/health.
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
    /// Session registry backing the chrome's session menu (toolbar toggle,
    /// Sessions submenu, New Session, Settings). The workspace is NOT one
    /// of its sessions — the menu's Appearance submenu stays hidden.
    let store: SessionStore
    /// Chrome menu actions, wired per presentation (iPad window: openWindow
    /// jump / in-window list sheet; iPhone cover: cover swap / dismiss).
    var onPickSession: (UUID) -> Void = { _ in }
    var onNewConnection: () -> Void = {}
    var fontModel: TerminalFontModel? = nil
    var embedConnection: Connection? = nil
    var embedHerd: HerdDescriptor? = nil
    var ownerID: UUID? = nil
    var hostKeyVerifier: HostKeyVerifier? = nil
    /// OSC 52 settings (default ON); nil falls back to a fresh shared
    /// instance. Workspace scenes pass `sessionStore.osc52Clipboard`.
    var osc52Settings: Osc52ClipboardSettings? = nil

    @State private var runtime = HerdrEmbedRuntime.shared
    @State private var osc52Toast: Osc52ClipboardToast? = nil
    @State private var osc52ToastTask: Task<Void, Never>? = nil

    init(
        endpointLabel: String,
        onClose: @escaping () -> Void,
        store: SessionStore,
        onPickSession: ((UUID) -> Void)? = nil,
        onNewConnection: (() -> Void)? = nil,
        fontModel: TerminalFontModel? = nil,
        runtime: HerdrEmbedRuntime = .shared,
        embedConnection: Connection? = nil,
        embedHerd: HerdDescriptor? = nil,
        ownerID: UUID? = nil,
        hostKeyVerifier: HostKeyVerifier? = nil,
        osc52Settings: Osc52ClipboardSettings? = nil
    ) {
        self.endpointLabel = endpointLabel
        self.onClose = onClose
        self.store = store
        self.onPickSession = onPickSession ?? { _ in }
        self.onNewConnection = onNewConnection ?? {}
        self.fontModel = fontModel
        self.embedConnection = embedConnection
        self.embedHerd = embedHerd
        self.ownerID = ownerID
        self.hostKeyVerifier = hostKeyVerifier
        self.osc52Settings = osc52Settings
        _runtime = State(initialValue: runtime)
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
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
        .overlay(alignment: .top) {
            if let toast = osc52Toast {
                Osc52ToastView(toast: toast, sceneID: "herdr")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: osc52Toast)
        .task {
            // Same warm as the session scene: the chrome menu's Sessions
            // submenu reads live state text from scene models.
            store.warmSceneModelsForSwitcher()
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
            osc52ToastTask?.cancel()
        }
        .modifier(EmbedPromptPresenter(coordinator: trustCoordinator))
    }

    /// Surface an approved OSC 52 toast on the workspace chrome. The
    /// workspace view IS that window's content for the duration of the
    /// presentation, so the gate is implicit in this entry-point being
    /// called at all (the view is mounted).
    private func presentOsc52Toast(_ toast: Osc52ClipboardToast) {
        osc52Toast = toast
        osc52ToastTask?.cancel()
        osc52ToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            osc52Toast = nil
        }
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

    private var chrome: some View {
        HerdrChromeView(
            store: store,
            title: endpointLabel,
            statusText: statusText,
            statusColor: statusColor,
            ownerID: ownerID,
            onPickSession: onPickSession,
            onNewConnection: onNewConnection,
            onClose: onClose
        )
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
            }
            .accessibilityIdentifier("herdr-embed-superseded")
        case .running:
            VStack(spacing: 0) {
                if !runtime.transportFailureLines.isEmpty {
                    VStack(alignment: .leading, spacing: spacing.xxs) {
                        ForEach(runtime.transportFailureLines, id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle")
                                .font(typography.caption)
                                .foregroundStyle(colors.error)
                                .accessibilityIdentifier("herdr-embed-transport-warning")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], spacing.sm)
                }
                HerdrTUIHostingView(
                    runtime: runtime,
                    fontModel: fontModel,
                    toolbarVisible: store.terminalToolbar.isVisible,
                    osc52Settings: osc52Settings ?? Osc52ClipboardSettings(),
                    osc52ForegroundCheck: nil,
                    osc52ToastPresenter: { toast in self.presentOsc52Toast(toast) },
                    osc52DenialRecorder: nil,
                    osc52SourceLabel: endpointLabel
                )
            }
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
            }
        case .stopped:
            VStack(spacing: spacing.sm) {
                Text(disconnectText)
                    .font(typography.body)
                    .foregroundStyle(colors.foreground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, spacing.sm)
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
        var line = "embed io ↑\(runtime.bytesWritten) ↓\(runtime.bytesRead)"
        if runtime.bytesDropped > 0 {
            line += " dropped=\(runtime.bytesDropped)"
        }
        return line
    }
    #else
    private var ioFootnote: String? { nil }
    #endif
}

/// Presents the embed transport's pending TOFU challenge or install
/// consent as ONE sheet above the workspace (the carrier connects while
/// this surface is already on screen; a prompt attached to the covered
/// connection list would never surface). Mirrors ``HerdPromptPresenter``.
private struct EmbedPromptPresenter: ViewModifier {
    let coordinator: HerdrEmbedTransportCoordinator?

    private enum PendingPrompt: Identifiable {
        case trust(HerdrEmbedTransportCoordinator.TrustPrompt)
        case install(HerdrEmbedTransportCoordinator.InstallPrompt)

        var id: UUID {
            switch self {
            case let .trust(prompt): prompt.id
            case let .install(prompt): prompt.id
            }
        }
    }

    private var pending: PendingPrompt? {
        guard let coordinator else { return nil }
        if let trust = coordinator.trustPrompt { return .trust(trust) }
        if let install = coordinator.installPrompt { return .install(install) }
        return nil
    }

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { pending },
                set: { _ in }
            )
        ) { prompt in
            Group {
                switch prompt {
                case let .trust(prompt):
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
                case let .install(prompt):
                    HerdrInstallConsentView(
                        consent: prompt.consent,
                        onInstall: { coordinator?.resolveInstallPrompt(true) },
                        onCancel: { coordinator?.resolveInstallPrompt(false) }
                    )
                }
            }
            .interactiveDismissDisabled(true)
            .presentationDetents([.large])
            .terminalStyle()
        }
    }
}
