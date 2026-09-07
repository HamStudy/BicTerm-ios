import SwiftUI

#if DEBUG
/// UITEST-only terminal preview surface (launch-argument gated):
/// a full-screen `TerminalRepresentable` connected to fixture hop1 via
/// `TerminalPreviewController`, plus a tail/status bar the UI tests
/// assert against.
struct TerminalPreviewScreen: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @StateObject private var controller = TerminalPreviewController()

    var body: some View {
        VStack(spacing: 0) {
            TerminalRepresentable(
                output: controller.viewOutput,
                send: { controller.send($0) },
                onResize: { cols, rows in controller.resize(cols: cols, rows: rows) },
                cursorStyle: .steadyBlock
            )
            .background(colors.background)

            VStack(alignment: .leading, spacing: 2) {
                Text("state:\(controller.phase.description)")
                    .accessibilityIdentifier("previewState")
                Text("dims:\(controller.dims)")
                    .accessibilityIdentifier("previewDims")
                Text(controller.tail.isEmpty ? " " : controller.tail)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .accessibilityIdentifier("previewTail")
            }
            .font(typography.caption)
            .foregroundColor(colors.dimmed)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background.opacity(0.95))
        }
        .background(colors.background.ignoresSafeArea())
        .onAppear { controller.start() }
        .onDisappear { Task { await controller.close() } }
    }
}

extension TerminalPreviewController.Phase {
    var description: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .ready: "ready"
        case .failed(let message): "failed:\(message)"
        }
    }
}
#endif
