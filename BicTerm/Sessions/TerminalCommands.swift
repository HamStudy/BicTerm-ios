import SwiftUI

/// One routable keyboard command. The chord mapping lives in
/// ``TerminalCommands``; the routing lives in
/// ``SessionStore/performTerminalCommand(_:)``.
enum TerminalCommandAction {
    case newSession
    case closeSession
    case nextSession
    case previousSession
    case settings
}

/// The focused terminal window's command surface: the window-local
/// presentations a keyboard command needs. Constructed by the terminal
/// window root, which owns the presentation state each closure drives —
/// the closures mirror the session menu's routing for the same actions.
struct TerminalCommandTarget {
    /// Present the connection list in the focused terminal window (the
    /// session menu's New Session action).
    let presentConnectionList: @MainActor () -> Void
    /// Switch the focused terminal window to another session: a detached
    /// session attaches in THIS window; a session hosted by another window
    /// focuses that window (never one session in two windows).
    let switchToSession: @MainActor (UUID) -> Void
    /// Open the independent Settings window (the session menu's Settings…
    /// action on iPad).
    let presentSettings: @MainActor () -> Void
}

/// The focused terminal scene: the session its window shows plus the
/// window-local actions commands dispatch to.
struct FocusedTerminalScene {
    let sessionID: UUID
    let target: TerminalCommandTarget
}

/// Routes hardware-keyboard commands to the focused terminal window.
///
/// Terminal windows register the scene they show while their scene phase
/// is `.active` (the key window — covered siblings report `.background`)
/// and retire it when they stop being active. Because ONLY terminal
/// windows ever register, a Settings or herdr window holding focus means
/// no registered scene: every terminal command is a strict no-op and
/// those scenes keep their own close/dismiss behavior. Activation can
/// land before the previous window's deactivation, so retiring only
/// clears the target when the retiring scene is the one that holds it.
@MainActor
@Observable
final class TerminalCommandsModel {
    private(set) var focused: FocusedTerminalScene?

    /// The session attached in the focused terminal window; nil when a
    /// non-terminal scene holds focus or no terminal window exists.
    var focusedSessionID: UUID? { focused?.sessionID }

    /// A terminal window became (or remains) the active scene.
    func noteFocusedTerminalScene(sessionID: UUID, target: TerminalCommandTarget) {
        focused = FocusedTerminalScene(sessionID: sessionID, target: target)
    }

    /// A terminal window stopped being the active scene (another window —
    /// terminal or not — took focus, or the app backgrounded).
    func noteTerminalSceneUnfocused(sessionID: UUID) {
        guard focused?.sessionID == sessionID else { return }
        focused = nil
    }

    /// The session-teardown path (``SessionStore/closeScene(_:)``) retires
    /// a closing session's target so commands never act on a dead scene.
    func noteSessionClosed(sessionID: UUID) {
        guard focused?.sessionID == sessionID else { return }
        focused = nil
    }
}

extension SessionStore {
    /// The single routing entry every keyboard command dispatches
    /// through — the SwiftUI Commands menu and the DEBUG UI-test seam
    /// alike. Resolves the focused terminal scene at invocation time and
    /// no-ops when a non-terminal scene holds focus.
    func performTerminalCommand(_ action: TerminalCommandAction) {
        switch action {
        case .newSession:
            terminalCommands.focused?.target.presentConnectionList()
        case .closeSession:
            requestCloseFocusedTerminalSession()
        case .nextSession:
            switchFocusedTerminalSession(forward: true)
        case .previousSession:
            switchFocusedTerminalSession(forward: false)
        case .settings:
            terminalCommands.focused?.target.presentSettings()
        }
    }
}

/// The app's hardware-keyboard commands, attached exactly ONCE at the
/// app boundary (SwiftUI merges scene commands app-wide, so a second
/// attach would duplicate every menu). Chords — the standard,
/// hold-Command-discoverable set:
///
///   ⌘N  New Session       — connection list in the focused terminal window
///   ⌘W  Close Session     — the focused session's EXISTING close confirmation
///   ⌘]  Next Session      — neighboring live session, wraparound
///   ⌘[  Previous Session  — neighboring live session, wraparound
///   ⌘,  Settings…         — the independent Settings window
///
/// Every action resolves the focused terminal scene at keypress time;
/// while a Settings or herdr scene holds focus they are no-ops. Chords
/// not claimed here keep falling through to terminal input.
struct TerminalCommands: Commands {
    let store: SessionStore

    var body: some Commands {
        CommandMenu("Session") {
            Button("New Session") {
                store.performTerminalCommand(.newSession)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Close Session") {
                store.performTerminalCommand(.closeSession)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Next Session") {
                store.performTerminalCommand(.nextSession)
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("Previous Session") {
                store.performTerminalCommand(.previousSession)
            }
            .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button("Settings…") {
                store.performTerminalCommand(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

#if DEBUG
/// Launch-argument gate for the terminal-commands UI-test seam
/// (`--uitest-terminal-commands`). DEBUG-only; compiled out of Release.
enum TerminalCommandsUITestSeam {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-terminal-commands")
    }
}

/// DEBUG-only XCUITest surface for the keyboard commands. XCUITest cannot
/// synthesize hardware Command chords on the simulator, so this strip
/// drives the REAL routing entry (``SessionStore/performTerminalCommand(_:)``
/// — the exact handler every registered chord dispatches through) and
/// exposes the focused-scene resolution as observable text. Mounted by
/// the terminal window root; the frontmost window's copy is the hittable
/// one, matching the session-menu tap pattern.
struct TerminalCommandsUITestSeamView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography

    let store: SessionStore

    var body: some View {
        HStack(spacing: 4) {
            Text("focus:\(focusedName)")
                .font(typography.caption)
                .accessibilityIdentifier("cmd-focus-status")
            Button("New") { store.performTerminalCommand(.newSession) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cmd-new")
            Button("Close") { store.performTerminalCommand(.closeSession) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cmd-close")
            Button("Next") { store.performTerminalCommand(.nextSession) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cmd-next")
            Button("Prev") { store.performTerminalCommand(.previousSession) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cmd-prev")
            Button("Settings") { store.performTerminalCommand(.settings) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cmd-settings")
        }
        .buttonStyle(.bordered)
        .font(typography.caption)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(colors.selection.opacity(0.9))
    }

    private var focusedName: String {
        guard let id = store.terminalCommands.focusedSessionID,
              let descriptor = store.descriptor(id: id)
        else { return "none" }
        return descriptor.connection.name
    }
}
#endif
