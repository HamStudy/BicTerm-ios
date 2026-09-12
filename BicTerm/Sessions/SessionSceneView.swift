import BicTermCore
import SwiftUI

/// Context-dependent actions a session surface triggers: picking another
/// session attaches it in the SAME presentation context (window swap,
/// cover swap, or window open), "New connection…" routes to the connection
/// list, and onSessionClosed fires when this scene's session terminates.
struct SessionSceneActions {
    var onPickSession: (UUID) -> Void
    var onNewConnection: () -> Void
    var onSessionClosed: () -> Void
}

/// One terminal session scene: chrome (connection name, protocol badge,
/// status, Sessions switcher, close), the terminal surface, status/reconnect
/// banner with typed error, close confirmation, and the agent approval sheet
/// for THIS scene's pending request.
struct SessionSceneView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let model: SessionSceneModel
    let store: SessionStore
    var actions: SessionSceneActions?

    @State private var switcherPresented = false

    private var agentPresenter: AgentApprovalPresenter { store.agentPresenter }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            if model.scrollbackReleased {
                scrollbackReleasedNotice
            }
            if model.state != .active || model.launchErrorMessage != nil {
                statusBanner
            }
            if model.isTerminalVisible {
                SessionTerminalRepresentable(
                    cache: store.viewCache,
                    model: model,
                    toolbarVisible: store.terminalToolbar.isVisible
                )
                .background(colors.background)
                .padding(.horizontal, store.effectiveMargin(model.sceneID).rawValue)
                .padding(.bottom, store.effectiveMargin(model.sceneID).rawValue)
            } else {
                closedPlaceholder
            }
            #if DEBUG
            debugStrip
            #endif
        }
        .background(colors.background.ignoresSafeArea())
        .sceneAppearance(store.effectiveTheme(model.sceneID))
        .task {
            // Every descriptor needs a scene model for the session menu's
            // live state text (same warm the switcher does on open).
            store.warmSceneModelsForSwitcher()
            await model.start()
        }
        .onChange(of: model.isClosed) { _, closed in
            if closed { actions?.onSessionClosed() }
        }
        .sheet(isPresented: $switcherPresented) {
            SessionSwitcherView(
                store: store,
                currentSessionID: model.id,
                onPick: { pickedID in
                    switcherPresented = false
                    actions?.onPickSession(pickedID)
                },
                onNewConnection: {
                    switcherPresented = false
                    actions?.onNewConnection()
                }
            )
        }
        .confirmationDialog(
            "Disconnect from \(model.connectionName)?",
            isPresented: closeConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                model.confirmClose()
            }
            .accessibilityIdentifier("scene-confirm-close")
            Button("Cancel", role: .cancel) {
                model.cancelClose()
            }
        } message: {
            Text("The remote session will be terminated.")
        }
        .sheet(isPresented: agentSheetBinding) {
            if let request = agentPresenter.pendingRequest {
                AgentApprovalSheetView(
                    request: request,
                    sessionDisplayName: agentPresenter.routing?.sessionDisplayName ?? model.connectionName,
                    onDecision: { agentPresenter.resolve($0) }
                )
            }
        }
        .sheet(isPresented: trustSheetBinding) {
            if let challenge = model.pendingTrustChallenge {
                HostTrustPromptView(
                    challenge: challenge,
                    errorMessage: model.trustErrorMessage,
                    onTrust: { Task { await model.trustPendingHost() } },
                    onCancel: { model.cancelTrustPrompt() }
                )
            }
        }
        .sheet(item: Binding(
            get: { store.passwordPresenter.requests[model.sceneID] },
            set: { if $0 == nil { store.passwordPresenter.cancel(sceneID: model.sceneID) } }
        )) { request in
            PasswordPromptView(request: request, presenter: store.passwordPresenter)
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text(model.connectionName)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .lineLimit(1)
                    .accessibilityIdentifier("scene-title-\(sanitized)")

                HStack(spacing: spacing.xxs) {
                    ProtocolBadge(protocolID: model.protocolID)
                    statusChip
                }
            }

            Spacer()

            SessionMenuView(
                store: store,
                currentSessionID: model.id,
                onPickSession: { pickedID in actions?.onPickSession(pickedID) },
                onNewConnection: { actions?.onNewConnection() },
                onManageSessions: { switcherPresented = true }
            )

            Button {
                model.requestClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Close session")
            .accessibilityIdentifier("scene-close-\(sanitized)")
            .foregroundColor(colors.dimmed)
        }
        .windowControlsClearance()
        .padding(.trailing, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.background)
    }

    private var scrollbackReleasedNotice: some View {
        HStack(spacing: spacing.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(colors.dimmed)
            Text("Scrollback released — earlier output was discarded.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .accessibilityIdentifier("scene-scrollback-released-\(sanitized)")
            Spacer()
            Button {
                model.clearScrollbackReleasedNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss notice")
            .accessibilityIdentifier("scene-scrollback-released-dismiss")
            .foregroundColor(colors.dimmed)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xxxs)
        .background(colors.selection.opacity(TerminalMetric.bannerFill))
    }

    private var statusChip: some View {
        TerminalBadge(model.statusText, tint: statusColor)
            .accessibilityIdentifier("scene-statuschip-\(sanitized)")
    }

    private var statusColor: Color {
        switch model.state {
        case .active: colors.success
        case .connecting, .reconnecting: colors.accent
        case .failed: colors.error
        case .disconnected, .suspended, .closed: colors.dimmed
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: spacing.xxxs) {
            HStack(spacing: spacing.xs) {
                Image(systemName: bannerIcon)
                    .foregroundColor(statusColor)
                Text(model.launchErrorMessage ?? model.statusText)
                    .font(typography.caption)
                    .foregroundColor(statusColor)
                    .accessibilityIdentifier("scene-banner-\(sanitized)")
                Spacer()
                if model.canRetry {
                    Button {
                        Task { await model.reconnect() }
                    } label: {
                        Text("Reconnect")
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("scene-reconnect-\(sanitized)")
                }
            }
            if let failure = model.failureMessage, model.launchErrorMessage == nil {
                Text(failure)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(2)
                    .accessibilityIdentifier("scene-failure-\(sanitized)")
            }
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.selection.opacity(TerminalMetric.bannerFill))
    }

    private var bannerIcon: String {
        switch model.state {
        case .failed: "exclamationmark.triangle.fill"
        case .suspended: "arrow.clockwise.circle"
        case .disconnected: "bolt.slash"
        default: "hourglass"
        }
    }

    private var closedPlaceholder: some View {
        VStack(spacing: spacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundColor(colors.dimmed)
            Text("Session ended")
                .font(typography.body)
                .foregroundColor(colors.dimmed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }

    #if DEBUG
    @ViewBuilder
    private var debugStrip: some View {
        if TerminalSceneUITest.seamsEnabled {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.uitestStatusDescription)
                    .accessibilityIdentifier("scene-status-\(sanitized)")
                Text("font:\(store.effectiveFontSize(model.sceneID)) theme:\(colorScheme == .dark ? "dark" : "light") margin:\(store.effectiveMargin(model.sceneID).rawValue)")
                    .accessibilityIdentifier("scene-appearance-\(sanitized)")
                Text(model.tail.isEmpty ? " " : model.tail)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .accessibilityIdentifier("scene-tail-\(sanitized)")
            }
            .font(typography.caption)
            .foregroundColor(colors.dimmed)
            .padding(.horizontal, spacing.xxs)
            .padding(.vertical, spacing.xxxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background.opacity(0.95))
        }
    }
    #endif

    // MARK: - Bindings

    private var closeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingCloseConfirmation },
            set: { if !$0 { model.cancelClose() } }
        )
    }

    private var agentSheetBinding: Binding<Bool> {
        Binding(
            get: { agentPresenter.isTargeting(scene: model.id) },
            set: { presented in
                if !presented { agentPresenter.denyPendingIfTargeting(scene: model.id) }
            }
        )
    }

    private var trustSheetBinding: Binding<Bool> {
        Binding(
            get: { model.isTrustPromptPresented },
            set: { presented in
                if !presented { model.cancelTrustPrompt() }
            }
        )
    }

    private var sanitized: String {
        model.connectionName.replacingOccurrences(of: " ", with: "-")
    }
}
