import SwiftUI

/// Machine switcher bar for herd workspaces (herdr-support plan todo 9).
/// Pure wrapper composition: the bar stacks ABOVE an unmodified
/// ``HerdrWorkspaceView``; selecting a chip retargets the model's
/// `selectedEndpointID` (surface interest) and the workspace body follows.
/// One component on iPhone and iPad — a horizontally scrolling chip row
/// that absorbs any machine count, Dynamic Type growth, and narrow Split
/// View widths.
struct HerdWorkspaceChromeView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let model: HerdrSessionModel
    let herd: HerdDescriptor
    let onClose: () -> Void
    let onSelectMachine: (HerdMachineDescriptor) -> Void
    var fontModel: TerminalFontModel? = nil

    var body: some View {
        VStack(spacing: 0) {
            machineBar
            HerdrWorkspaceView(
                model: model,
                endpointLabel: herd.herdName,
                onClose: onClose,
                fontModel: fontModel
            )
        }
        .background {
            cycleShortcuts
        }
    }

    // MARK: - Machine bar

    private var machineBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing.xs) {
                ForEach(herd.machines) { machine in
                    MachineChip(
                        label: machine.label,
                        sessionName: machine.sessionName,
                        state: chipState(for: machine),
                        isSelected: model.selectedEndpointID == machine.endpointID
                    ) {
                        onSelectMachine(machine)
                    }
                }
            }
            .padding(.horizontal, spacing.sm)
            .padding(.vertical, spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .bottom) {
            Divider().overlay(colors.dimmed.opacity(0.5))
        }
        .accessibilityIdentifier("herd-machine-bar")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Machines")
    }

    private func chipState(
        for machine: HerdMachineDescriptor
    ) -> MachineChip.State {
        switch model.endpoints[machine.endpointID]?.phase {
        case .connecting: .connecting
        case nil: .offline
        case .online: .online
        case .reconnecting: .reconnecting
        case .failed: .needsAttention
        case .disconnected: .offline
        }
    }

    // MARK: - Keyboard cycling

    /// cmd+shift+[ / ] cycle machines (no collision with herdr's ctrl+b
    /// prefix: different modifiers entirely). Hidden buttons carry the
    /// shortcuts; the visible chips stay plain taps.
    private var cycleShortcuts: some View {
        Group {
            Button("Previous Machine") { cycle(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Machine") { cycle(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cycle(_ direction: Int) {
        let machines = herd.machines
        guard !machines.isEmpty else { return }
        let current = machines.firstIndex {
            $0.endpointID == model.selectedEndpointID
        } ?? 0
        let next = (current + direction + machines.count) % machines.count
        onSelectMachine(machines[next])
    }
}

/// One machine chip: label plus a state indicator that never relies on
/// color alone — each state carries its own symbol and word, in the chip's
/// visible text and its accessibility label.
struct MachineChip: View {
    enum State: Equatable {
        case connecting
        case online
        case reconnecting
        case needsAttention
        case offline

        var word: String {
            switch self {
            case .connecting: "Connecting"
            case .online: "Online"
            case .reconnecting: "Reconnecting"
            case .needsAttention: "Needs Attention"
            case .offline: "Offline"
            }
        }

        var symbol: String {
            switch self {
            case .connecting: "hourglass"
            case .online: "checkmark.circle.fill"
            case .reconnecting: "arrow.triangle.2.circlepath"
            case .needsAttention: "exclamationmark.triangle.fill"
            case .offline: "minus.circle"
            }
        }
    }

    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let label: String
    let sessionName: String?
    let state: State
    let isSelected: Bool
    let action: () -> Void

    private var stateColor: Color {
        switch state {
        case .connecting: colors.dimmed
        case .online: colors.success
        case .reconnecting: colors.accent
        case .needsAttention: colors.error
        case .offline: colors.dimmed
        }
    }

    private var accessibilityText: String {
        var parts = [label]
        if let sessionName, !sessionName.isEmpty {
            parts.append("session \(sessionName)")
        }
        parts.append(state.word)
        if isSelected {
            parts.append("selected")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing.xxxs) {
                Image(systemName: state.symbol)
                    .foregroundStyle(stateColor)
                    .imageScale(.small)
                Text(label)
                    .font(typography.caption)
                    .foregroundStyle(isSelected ? colors.foreground : colors.dimmed)
                    .lineLimit(1)
            }
            .padding(.horizontal, spacing.sm)
            .frame(minHeight: 36)
            .padding(.vertical, spacing.xxxs)
            .background(
                isSelected ? colors.selection.opacity(0.6) : colors.background,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? colors.accent : colors.dimmed.opacity(0.5),
                    lineWidth: isSelected ? 2 : 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .frame(minHeight: 44)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("herd-chip-\(label.replacingOccurrences(of: " ", with: "-"))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
