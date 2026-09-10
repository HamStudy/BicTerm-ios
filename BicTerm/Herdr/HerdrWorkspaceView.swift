import HerdrClientCore
import OSLog
import SwiftUI

/// Native herdr workspace chrome (integration doc §7 Option A): endpoint
/// header + phase badge, tab bar for the focused workspace, pane area
/// (committed surface cells when available, snapshot pane tree otherwise),
/// informational notification strip, and the version-gate diagnostic screen.
///
/// All rendering consumes immutable model state — snapshots and surfaces
/// applied inside the Rust core; no VT re-parse, no ANSI re-encode.
struct HerdrWorkspaceView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let model: HerdrSessionModel
    let endpointLabel: String
    let onClose: () -> Void

    private static let logger = Logger(
        subsystem: "com.bicterm.app.herdr",
        category: "workspace-chrome"
    )

    private var state: HerdrEndpointState? {
        guard let id = model.selectedEndpointID else { return nil }
        return model.endpoints[id]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let state, state.phase == .failed || state.phase == .disconnected,
               let diagnostic = state.diagnostic {
                HerdrDiagnosticView(
                    diagnostic: diagnostic,
                    endpointLabel: endpointLabel,
                    onDismiss: onClose
                )
            } else {
                workspaceBody
            }
        }
        .background(colors.background.ignoresSafeArea())
        .onAppear {
            // Informational (plan T16): record the chrome's Dynamic Type
            // context; survival itself is asserted by the UI test's
            // accessibility-size relaunch.
            Self.logger.info(
                "herdr chrome rendered at dynamic type size \(String(describing: dynamicTypeSize), privacy: .public)"
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text("Herdr — \(endpointLabel)")
                    .font(typography.headline)
                    .foregroundStyle(colors.foreground)
                    .accessibilityIdentifier("herdr-endpoint-label")
                if let state {
                    Text(phaseText(state.phase))
                        .font(typography.caption)
                        .foregroundStyle(phaseColor(state.phase))
                        .accessibilityIdentifier("herdr-status-badge")
                }
            }
            Spacer()
            Button("Disconnect", action: disconnect)
                .font(typography.body)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("herdr-disconnect")
        }
        .padding([.horizontal, .top], spacing.sm)
        .padding(.bottom, spacing.xs)
    }

    // MARK: - Workspace body

    private var workspaceBody: some View {
        let snapshot = state?.snapshot
        let surface = state?.surface
        return VStack(spacing: 0) {
            if let snapshot {
                notificationStrip(snapshot: snapshot)
                tabBar(snapshot: snapshot)
                paneArea(snapshot: snapshot, surface: surface)
            } else {
                connectingIndicator
            }
            if state?.surfaceUnavailable == true {
                surfaceUnavailableNote
            }
        }
    }

    private var connectingIndicator: some View {
        VStack(spacing: spacing.sm) {
            ProgressView()
            Text("Connecting to Herdr")
                .font(typography.body)
                .foregroundStyle(colors.dimmed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("herdr-connecting")
    }

    private func notificationStrip(snapshot: HerdrShellSnapshot) -> some View {
        let notes = Self.notifications(from: snapshot)
        return Group {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: spacing.xxs) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        Label(note, systemImage: "info.circle")
                            .font(typography.caption)
                            .foregroundStyle(colors.dimmed)
                            .lineLimit(2)
                            .accessibilityIdentifier("herdr-notification-\(index)")
                    }
                }
                .padding(.horizontal, spacing.sm)
                .padding(.vertical, spacing.xxs)
                .background(colors.selection.opacity(0.25))
            }
        }
    }

    /// Informational only (integration doc §11): remote announcements are
    /// never actionable here — no install/update commands are surfaced.
    static func notifications(from snapshot: HerdrShellSnapshot) -> [String] {
        var notes: [String] = []
        if let diagnostic = snapshot.configDiagnostic {
            notes.append("Server configuration: \(diagnostic)")
        }
        if let announcement = snapshot.productAnnouncement {
            notes.append(announcement.title)
        }
        if let update = snapshot.updateAvailable {
            notes.append("Update available on the host: \(update)")
        }
        return notes
    }

    private func tabBar(snapshot: HerdrShellSnapshot) -> some View {
        let workspaceID = snapshot.focusedWorkspaceID
            ?? snapshot.workspaces.first?.workspaceID
        let tabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing.xs) {
                ForEach(tabs, id: \.tabID) { tab in
                    Button(action: {}) {
                        Text(tab.label)
                            .font(typography.caption)
                            .padding(.horizontal, spacing.sm)
                            .padding(.vertical, spacing.xxs)
                            .background(
                                tab.focused ? colors.selection : colors.background,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(tab.focused ? colors.accent : colors.dimmed, lineWidth: 1)
                            )
                    }
                    .foregroundStyle(tab.focused ? colors.foreground : colors.dimmed)
                    .accessibilityLabel("Tab \(tab.number): \(tab.label)\(tab.focused ? ", selected" : "")")
                    .accessibilityIdentifier("herdr-tab-\(tab.number)")
                    .accessibilityAddTraits(tab.focused ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, spacing.sm)
            .padding(.bottom, spacing.xs)
        }
        .accessibilityIdentifier("herdr-tab-bar")
    }

    @ViewBuilder
    private func paneArea(
        snapshot: HerdrShellSnapshot,
        surface: HerdrPaneSurface?
    ) -> some View {
        if let surface {
            HerdrPaneSurfaceView(
                surface: surface,
                paneMetadata: paneMetadata(from: snapshot)
            )
        } else {
            snapshotPaneGrid(snapshot: snapshot)
        }
    }

    /// Snapshot-driven pane tree (identity, focus, cwd): the committed
    /// FFI cannot hand over cell surfaces yet (probe evidence), so until a
    /// surface commits the pane tree renders from the authoritative
    /// snapshot metadata. The layout is presentation-only — the remote
    /// owns the real geometry, which arrives with the surface.
    private func snapshotPaneGrid(snapshot: HerdrShellSnapshot) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: spacing.xs) {
                ForEach(snapshot.panes, id: \.paneID) { pane in
                    VStack(alignment: .leading, spacing: spacing.xxs) {
                        HStack(spacing: spacing.xxs) {
                            if pane.focused {
                                Image(systemName: "rectangle.inset.filled")
                                    .foregroundStyle(colors.accent)
                            }
                            Text(pane.label ?? pane.paneID)
                                .font(typography.caption.weight(.semibold))
                                .foregroundStyle(colors.foreground)
                        }
                        if let cwd = pane.cwd {
                            Text(cwd)
                                .font(typography.caption)
                                .foregroundStyle(colors.dimmed)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(spacing.xs)
                    .background(colors.selection.opacity(pane.focused ? 0.6 : 0.25), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(pane.focused ? colors.accent : colors.dimmed.opacity(0.5), lineWidth: pane.focused ? 2 : 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(paneAccessibilityLabel(pane))
                    .accessibilityIdentifier("herdr-pane-\(pane.paneID)")
                    .accessibilityAddTraits(pane.focused ? [.isSelected] : [])
                }
            }
            .padding(spacing.sm)
        }
    }

    private var surfaceUnavailableNote: some View {
        Text("Live pane surfaces are unavailable in this build; showing the workspace pane tree.")
            .font(typography.caption)
            .foregroundStyle(colors.dimmed)
            .padding(.horizontal, spacing.sm)
            .padding(.vertical, spacing.xxs)
            .accessibilityIdentifier("herdr-surface-unavailable")
    }

    // MARK: - Actions

    private func disconnect() {
        Task {
            await model.disconnectAll()
            onClose()
        }
    }

    // MARK: - Helpers

    private func paneMetadata(from snapshot: HerdrShellSnapshot) -> [String: String] {
        var metadata: [String: String] = [:]
        for pane in snapshot.panes where pane.paneID == snapshot.focusedPaneID {
            metadata[pane.paneID] = pane.cwd ?? pane.label ?? ""
        }
        for pane in snapshot.panes where pane.paneID != snapshot.focusedPaneID {
            metadata[pane.paneID] = pane.label ?? ""
        }
        return metadata
    }

    private func paneAccessibilityLabel(_ pane: HerdrPane) -> String {
        var parts = ["Pane \(pane.paneID)"]
        parts.append(pane.focused ? "focused" : "background")
        if let label = pane.label {
            parts.append(label)
        }
        if let cwd = pane.cwd {
            parts.append(cwd)
        }
        return parts.joined(separator: ", ")
    }

    private func phaseText(_ phase: HerdrEndpointPhase) -> String {
        switch phase {
        case .connecting: "Connecting"
        case .online: "Online"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }

    private func phaseColor(_ phase: HerdrEndpointPhase) -> Color {
        switch phase {
        case .connecting: colors.dimmed
        case .online: colors.success
        case .disconnected: colors.dimmed
        case .failed: colors.error
        }
    }
}
