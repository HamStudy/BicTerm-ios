import BicTermCore
import SwiftUI

// MARK: - Snippet Insert and confirmed Run (t8)

/// One immutable Run request captured when the user taps a snippet's
/// Run button. The captured command is the ONLY text ever delivered on
/// confirm, and the target connection name travels with the request so
/// the confirmation shows exactly where the bytes will go. Value
/// semantics with a fresh identity per request, mirroring
/// ``TerminalPasteRequest``.
struct TerminalSnippetRunRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let snippetName: String
    let command: String
    let connectionName: String

    init(snippetName: String, command: String, connectionName: String) {
        self.id = UUID()
        self.snippetName = snippetName
        self.command = command
        self.connectionName = connectionName
    }
}

/// The session scene's snippet surface: global plus current-connection
/// snippets with Insert (exact bytes, no Return) and Run (confirmed
/// bytes + CR). While a Run request is pending and its attachment
/// generation is current, the sheet shows the confirmation instead of
/// the list — one modal, never stacked sheets.
struct SnippetPickerSheet: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dismiss) private var dismiss

    let model: SessionSceneModel

    var body: some View {
        Group {
            if let request = model.currentSnippetRunRequest {
                TerminalSnippetRunConfirmationSheet(
                    request: request,
                    errorMessage: model.snippetRunErrorMessage,
                    onRun: {
                        Task {
                            await model.confirmSnippetRun()
                            if model.snippetRunErrorMessage == nil {
                                dismiss()
                            }
                        }
                    },
                    onCancel: { model.cancelSnippetRunConfirmation() }
                )
            } else {
                list
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.reloadSnippets() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: spacing.xs) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(typography.headline)
                    .foregroundColor(colors.accent)
                Text("Snippets")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                Spacer()
                Button("Done") { dismiss() }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("snippet-sheet-done")
            }
            .padding(.horizontal, spacing.lg)
            .padding(.top, spacing.sm)
            .padding(.bottom, spacing.xs)

            if let loadError = model.snippetLoadError {
                Text(loadError)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, spacing.lg)
                    .padding(.bottom, spacing.xs)
                    .accessibilityIdentifier("snippet-load-error")
            } else if model.snippets.isEmpty {
                VStack(spacing: spacing.xs) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(typography.title)
                        .foregroundColor(colors.dimmed)
                    Text("No snippets")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                    Text("Create global snippets in Settings → Snippets.")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(spacing.lg)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.snippets) { snippet in
                            SnippetPickerRow(
                                snippet: snippet,
                                onInsert: {
                                    Task {
                                        await model.insertSnippet(snippet)
                                        if model.snippetErrorMessage == nil {
                                            dismiss()
                                        }
                                    }
                                },
                                onRun: {
                                    model.presentSnippetRunConfirmation(TerminalSnippetRunRequest(
                                        snippetName: snippet.name,
                                        command: snippet.command,
                                        connectionName: model.connectionName
                                    ))
                                }
                            )
                        }
                    }
                }
            }

            if let sendError = model.snippetErrorMessage {
                Text(sendError)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, spacing.lg)
                    .padding(.vertical, spacing.xs)
                    .accessibilityIdentifier("snippet-send-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snippet-picker-sheet")
    }
}

/// One snippet row: name, command preview, Insert, and Run.
private struct SnippetPickerRow: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let snippet: Snippet
    let onInsert: () -> Void
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(snippet.name)
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                Text(snippet.command)
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button("Insert", action: onInsert)
                .buttonStyle(.bordered)
                .tint(colors.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("snippet-insert-\(sanitized)")
            Button("Run", action: onRun)
                .buttonStyle(.borderedProminent)
                .tint(colors.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("snippet-run-\(sanitized)")
        }
        .padding(.horizontal, spacing.lg)
        .padding(.vertical, spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snippet-row-\(sanitized)")
    }

    private var sanitized: String {
        snippet.name.replacingOccurrences(of: " ", with: "-")
    }
}

/// Host-visible confirmation for one snippet Run: the exact command,
/// the target connection name, Run delivering exactly those bytes plus
/// CR through the scene model's confirmed path, and Cancel (or the
/// sheet's dismissal) sending nothing. A failed delivery keeps the
/// confirmation up with the error inline.
struct TerminalSnippetRunConfirmationSheet: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    static let commandLineLimit = 3

    let request: TerminalSnippetRunRequest
    let errorMessage: String?
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.sm) {
            HStack(spacing: spacing.xs) {
                Image(systemName: "arrow.right.circle")
                    .font(typography.headline)
                    .foregroundColor(colors.accent)
                Text("Run Snippet?")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
            }
            Text("Runs on \(request.connectionName)")
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier("snippet-run-target")
            Text(request.command)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
                .lineLimit(Self.commandLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.selection.opacity(TerminalMetric.bannerFill))
                .accessibilityIdentifier("snippet-run-command")
            if let errorMessage {
                Text(errorMessage)
                    .font(typography.caption)
                    .foregroundColor(colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("snippet-run-error")
            }
            HStack(spacing: spacing.sm) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("snippet-run-cancel")
                Button("Run", action: onRun)
                    .buttonStyle(.borderedProminent)
                    .tint(colors.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("snippet-run-confirm")
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snippet-run-confirmation")
    }
}
