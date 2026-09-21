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
    /// Local mirror of `model.osc52Toast` written from the
    /// `osc52ToastPresenter` callback on surface attach. `@Observable`
    /// observation through the SessionSceneModel setter was firing the
    /// `body` (NSLog confirmed) but SwiftUI was using a cached render
    /// that didn't pick up the structural change — the local `@State`
    /// mirror writes via `MainActor.run` and SwiftUI's `@State` tracking
    /// guarantees a structural re-render. This is the security guardrail
    /// of OSC 52; rendering MUST happen.
    @State private var renderedOsc52Toast: Osc52ClipboardToast?
    /// Same mirror pattern for the OSC 777 banner (see
    /// `renderedOsc52Toast` for the render-cache rationale).
    @State private var renderedNotificationBanner: TerminalNotificationBanner?

    private var agentPresenter: AgentApprovalPresenter { store.agentPresenter }

    var body: some View {
        let toastToShow = renderedOsc52Toast ?? model.osc52Toast
        let bannerToShow = renderedNotificationBanner ?? model.notificationBanner
        return VStack(spacing: 0) {
            Group {
                if let osc52Toast = toastToShow {
                    Osc52ToastView(
                        toast: osc52Toast,
                        palette: colors,
                        typography: typography,
                        spacing: spacing,
                        sceneID: sanitized
                    )
                }
            }
            Group {
                if let notificationBanner = bannerToShow {
                    TerminalNotificationBannerView(
                        banner: notificationBanner,
                        palette: colors,
                        typography: typography,
                        spacing: spacing,
                        onDismiss: { model.dismissNotificationBanner() },
                        sceneID: sanitized
                    )
                }
            }
            chrome
            if model.scrollbackReleased {
                scrollbackReleasedNotice
            }
            if model.syncSuspect {
                syncSuspectBanner
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
        .overlay(alignment: .top) {
            VStack(spacing: spacing.xs) {
                if model.showReconnectedToast {
                    reconnectedToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .onChange(of: model.osc52Toast) { _, new in
            // Bridge the @Observable model write to a local @State mirror.
            // The @Observable property change reliably invalidates this view,
            // but the structural rebuild was skipping the conditional view
            // (confirmed by NSLog inside body firing with the new value but
            // no render change observed in burst screenshots). The local
            // @State write forces an explicit structural invalidation here.
            renderedOsc52Toast = new
        }
        .onChange(of: model.notificationBanner) { _, new in
            renderedNotificationBanner = new
        }
        .animation(.easeInOut(duration: 0.2), value: model.showReconnectedToast)
        .animation(.easeInOut(duration: 0.2), value: model.osc52Toast)
        .animation(.easeInOut(duration: 0.2), value: model.notificationBanner)
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
        .sheet(item: linkRequestSheetBinding) { request in
            TerminalLinkConfirmationSheet(
                request: request,
                onOpen: { model.confirmLinkOpen() },
                onCancel: { model.cancelLinkConfirmation() }
            )
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
                    .font(typography.title)
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
                    .font(typography.caption)
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

    /// Anomaly surface: shown when the inbound chain detected dropped
    /// bytes (the screen may render garbage). One tap rebuilds the screen
    /// from fresh remote state.
    private var syncSuspectBanner: some View {
        HStack(spacing: spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(colors.error)
            Text("Screen may be out of sync")
                .font(typography.caption)
                .foregroundColor(colors.error)
            Spacer()
            Button {
                model.resyncNow()
            } label: {
                Text("Resync")
            }
            .buttonStyle(.bordered)
            .tint(colors.accent)
            .accessibilityIdentifier("scene-resync-\(sanitized)")
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xxxs)
        .background(colors.selection.opacity(TerminalMetric.bannerFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen may be out of sync. Resync available.")
        .accessibilityIdentifier("scene-sync-banner-\(sanitized)")
    }

    private var reconnectedToast: some View {
        HStack(spacing: spacing.xs) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundColor(colors.success)
            Text("Reconnected — screen refreshed")
                .font(typography.caption)
                .foregroundColor(colors.foreground)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.selection.opacity(0.9), in: Capsule())
        .accessibilityIdentifier("scene-reconnected-toast")
        .padding(.top, spacing.xs)
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
                .font(typography.title)
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
                Text(model.uitestSyncDescription)
                    .accessibilityIdentifier("scene-sync-\(sanitized)")
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

    /// Swipe-down on the link sheet is a cancel: it sends nothing.
    private var linkRequestSheetBinding: Binding<TerminalLinkRequest?> {
        Binding(
            get: { model.pendingLinkRequest },
            set: { if $0 == nil { model.cancelLinkConfirmation() } }
        )
    }

    private var sanitized: String {
        model.connectionName.replacingOccurrences(of: " ", with: "-")
    }
}
