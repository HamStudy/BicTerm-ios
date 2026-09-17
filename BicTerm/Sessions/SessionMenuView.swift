import BicTermCore
import SwiftUI

/// The session scene's top-right menu (ellipsis): absorbs the old keyboard
/// and sessions chrome buttons into ONE control, leaving exactly two
/// top-right chrome items — this menu and Close. Item order is the user
/// directive:
///
///   1. Terminal Toolbar — same toggle as the old keyboard chrome button
///      (app-global `TerminalToolbarModel`), with live On/Off state.
///   2. Sessions — submenu listing every open session with live state;
///      tapping one JUMPS to it (iPad: focus the window hosting it,
///      opening a window for detached sessions; iPhone: activate it in
///      this scene via the same code path as the switcher sheet), plus
///      "Manage Sessions…" opening the full switcher sheet.
///   3. New Session — routes to the connection list (the same action as
///      the switcher's "New connection…" row).
///   4. Settings… — iPad: the standalone Settings window; iPhone: a sheet.
///
struct SessionMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.terminalColors) private var colors

    let store: SessionStore
    /// The session attached in THIS scene (marked, and not jumpable).
    let currentSessionID: UUID
    /// Appended to every accessibility identifier in the menu. The herdr
    /// workspace chrome passes "-herdr" so a herdr window and a terminal
    /// window on screen together (iPad) never duplicate the session
    /// scene's identifiers; the terminal scene keeps the default "".
    var identifierSuffix: String = ""
    var onPickSession: (UUID) -> Void
    var onNewConnection: () -> Void
    var onManageSessions: () -> Void

    @State private var settingsPresented = false
    @State private var fontEditorPresented = false

    var body: some View {
        Menu {
            toolbarToggleItem
            sessionsSubmenu
            newSessionItem
            if let descriptor = store.descriptor(id: currentSessionID) {
                SessionAppearanceMenu(store: store, sceneID: descriptor.registrySceneID,
                                      onEditFont: { fontEditorPresented = true })
            }
            Divider()
            settingsItem
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Session menu")
        .accessibilityIdentifier("scene-menu\(identifierSuffix)")
        .foregroundColor(colors.dimmed)
        .sheet(isPresented: $fontEditorPresented) {
            if let descriptor = store.descriptor(id: currentSessionID) {
                SessionFontSettingsView(store: store, sceneID: descriptor.registrySceneID)
                    .terminalStyle()
            }
        }
        .sheet(isPresented: $settingsPresented) {
            NavigationStack {
                SettingsView(
                    fontModel: store.terminalFont,
                    themeModel: store.theme,
                    osc52Model: store.osc52Clipboard
                )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { settingsPresented = false }
                                .accessibilityIdentifier("menu-settings-done\(identifierSuffix)")
                        }
                    }
            }
            .terminalStyle()
        }
    }

    // MARK: - Items

    private var toolbarToggleItem: some View {
        Button {
            store.terminalToolbar.toggle()
        } label: {
            Label(
                store.terminalToolbar.isVisible ? "Terminal Toolbar: On" : "Terminal Toolbar: Off",
                systemImage: "keyboard"
            )
        }
        .accessibilityIdentifier("terminal-toolbar-toggle\(identifierSuffix)")
    }

    private var sessionsSubmenu: some View {
        Menu {
            ForEach(rows) { row in
                SessionMenuRow(
                    descriptor: row.descriptor,
                    key: row.key,
                    store: store,
                    isCurrent: row.descriptor.id == currentSessionID,
                    identifierSuffix: identifierSuffix,
                    onJump: jump
                )
            }
            if !rows.isEmpty {
                Divider()
            }
            Button {
                onManageSessions()
            } label: {
                Label("Manage Sessions…", systemImage: "rectangle.on.rectangle")
            }
            .accessibilityIdentifier("scene-manage-sessions\(identifierSuffix)")
        } label: {
            Label("Sessions", systemImage: "rectangle.on.rectangle")
        }
        .accessibilityIdentifier("scene-sessions\(identifierSuffix)")
    }

    private var newSessionItem: some View {
        Button {
            onNewConnection()
        } label: {
            Label("New Session", systemImage: "plus")
        }
        .accessibilityIdentifier("scene-new-session\(identifierSuffix)")
    }

    private var settingsItem: some View {
        Button {
            if supportsMultipleWindows {
                openWindow(id: "settings", value: SettingsWindowValue.main)
            } else {
                settingsPresented = true
            }
        } label: {
            Label("Settings…", systemImage: "gear")
        }
        .accessibilityIdentifier("scene-settings\(identifierSuffix)")
    }

    // MARK: - Jump

    /// iPad: focus the window already hosting the session (its registered
    /// window value), or open a NEW window for a detached session — one
    /// window per session, never the same session attached twice. iPhone:
    /// single-scene activation through the switcher's code path.
    private func jump(to sessionID: UUID) {
        guard sessionID != currentSessionID else { return }
        if supportsMultipleWindows {
            let windowValue = store.hostingWindowValue(for: sessionID) ?? sessionID
            openWindow(id: "terminal", value: SessionID(value: windowValue))
        } else {
            onPickSession(sessionID)
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        let descriptor: SessionStore.SessionDescriptor
        let key: String

        var id: UUID { descriptor.id }
    }

    /// Same duplicate-name keying as the switcher ("Name-1", "Name-2"…)
    /// so menu row identifiers stay predictable in UI tests.
    private var rows: [Row] {
        var counts: [String: Int] = [:]
        return store.orderedDescriptors.map { descriptor in
            let base = descriptor.connection.name.replacingOccurrences(of: " ", with: "-")
            counts[base, default: 0] += 1
            return Row(descriptor: descriptor, key: "\(base)-\(counts[base] ?? 1)")
        }
    }
}

/// One session row inside the Sessions submenu: name (+ unread dot), live
/// state text, a checkmark on the session attached in this scene. Tapping
/// jumps to the session; the current row is display-only.
private struct SessionMenuRow: View {
    let descriptor: SessionStore.SessionDescriptor
    let key: String
    let store: SessionStore
    let isCurrent: Bool
    var identifierSuffix: String = ""
    let onJump: (UUID) -> Void

    @State private var hasUnseenOutput = false

    var body: some View {
        Button {
            onJump(descriptor.id)
        } label: {
            Label {
                // One Text with an embedded newline: iOS flattens a menu
                // item to a single AX element and exposes only the FIRST
                // Text of a VStack, so name and state must share one Text
                // for VoiceOver (and UI tests) to read both.
                Text("\(hasUnseenOutput ? "● " : "")\(descriptor.connection.name)\n\(stateText)")
            } icon: {
                Image(systemName: isCurrent ? "checkmark" : "terminal")
            }
        }
        .disabled(isCurrent)
        .accessibilityIdentifier("menu-session-\(key)\(identifierSuffix)")
        .task { await pollUnseenOutput() }
    }

    private var model: SessionSceneModel? {
        store.existingModel(for: descriptor.id)
    }

    /// Same state strings as the switcher rows.
    private var stateText: String {
        let base: String = switch model?.state {
        case .active: "connected"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .suspended: "reconnect required"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed, .none: "ended"
        }
        return isCurrent ? "\(base) — current" : base
    }

    /// The unread flag is registry-owned actor state (not observable) —
    /// poll it while the row is on screen (same pattern as the switcher).
    private func pollUnseenOutput() async {
        let sceneID = descriptor.registrySceneID
        while !Task.isCancelled {
            if let presentation = await store.registry.presentationState(sceneID: sceneID) {
                hasUnseenOutput = presentation.hasUnseenOutput
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
