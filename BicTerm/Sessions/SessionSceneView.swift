import BicTermCore
import SwiftUI

/// One terminal session scene: chrome (connection name, protocol badge,
/// status), the terminal surface, status/reconnect banner with typed error,
/// close confirmation, and the agent approval sheet for THIS scene's
/// pending request.
struct SessionSceneView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let model: SessionSceneModel
    let agentPresenter: AgentApprovalPresenter
    var onSessionClosed: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            chrome
            if model.state != .active || model.launchErrorMessage != nil {
                statusBanner
            }
            if model.isTerminalVisible {
                TerminalRepresentable(
                    output: model.viewOutput,
                    send: { model.send($0) },
                    onResize: { cols, rows in model.resize(cols: cols, rows: rows) },
                    cursorStyle: .steadyBlock
                )
                .background(colors.background)
            } else {
                closedPlaceholder
            }
            #if DEBUG
            debugStrip
            #endif
        }
        .background(colors.background.ignoresSafeArea())
        .task { await model.start() }
        .onAppear { model.sceneViewAppeared() }
        .onDisappear { model.sceneViewDisappeared() }
        .onChange(of: model.isClosed) { _, closed in
            if closed { onSessionClosed?() }
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

            Button {
                model.requestClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Close session")
            .accessibilityIdentifier("scene-close-\(sanitized)")
            .foregroundColor(colors.dimmed)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.background)
    }

    private var statusChip: some View {
        Text(model.statusText)
            .font(typography.caption)
            .foregroundColor(statusColor)
            .padding(.horizontal, spacing.xs)
            .padding(.vertical, spacing.xxxs)
            .background(statusColor.opacity(0.15), in: Capsule())
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
        .background(colors.selection.opacity(0.4))
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
