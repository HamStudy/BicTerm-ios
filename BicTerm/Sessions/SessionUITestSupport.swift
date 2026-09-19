#if DEBUG
import BicTermCore
import Foundation
import SwiftUI

/// Launch-argument contract for the session-scene UI tests (DEBUG only;
/// every seam compiles out of Release):
///
///   --uitest-sessions                      enable scene seams + driver below
///   --uitest-expect-restore                keep snapshots at launch (restore test relaunch)
///   --uitest-open-session <name>           connect the named connection at bootstrap (repeatable)
///   --uitest-open-session-detached <name>  open + start WITHOUT presenting (switcher tests; repeatable)
///   --uitest-open-session-after <n>:<sec>  open a second-wave session after a delay
///   --uitest-session-command <cmd>         send cmd to each opened session once active ({NAME} substituted)
///   --uitest-keep-toolbar-pref             keep the persisted toolbar visibility choice (relaunch tests)
///   --uitest-keep-font-pref                keep the persisted terminal font size (persistence tests)
///   --uitest-keep-theme-pref               keep the persisted appearance preference (persistence tests)
enum TerminalSceneUITest {
    static var seamsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-sessions")
    }

    static func values(after flag: String) -> [String] {
        let arguments = ProcessInfo.processInfo.arguments
        var result: [String] = []
        var searchStart = arguments.startIndex
        while let index = arguments[searchStart...].firstIndex(of: flag) {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { break }
            result.append(arguments[next])
            searchStart = arguments.index(after: next)
        }
        return result
    }

    static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

/// Bootstrap-time driver for session-scene UI tests: opens the requested
/// fixture connections as real scenes and (optionally) sends a command into
/// each once its session is active — standing in for the cross-window
/// interaction XCUITest cannot synthesize on iPad.
enum SessionUITestDriver {
    @MainActor private static var hasStarted = false

    @MainActor
    static func run(
        store: SessionStore,
        present: @MainActor (SessionStore.SessionDescriptor) -> Void
    ) async {
        guard TerminalSceneUITest.seamsEnabled, !hasStarted else { return }
        hasStarted = true
        let arguments = ProcessInfo.processInfo.arguments

        if !arguments.contains("--uitest-expect-restore") {
            await store.clearSnapshotsForUITests()
        }

        // The persisted host-key store outlives the app inside the
        // simulator container: without a wipe, a Trust gesture from an
        // earlier run skips the unknown-host prompt in every later run.
        // Pretrusted launches use an isolated in-memory store instead.
        if !arguments.contains("--uitest-pretrust-fixtures") {
            await store.clearHostKeysForUITests()
        }

        // The toolbar visibility pref is app-global UserDefaults state that
        // survives relaunches: reset it to the hardware-keyboard heuristic
        // unless the test deliberately exercises persistence.
        if !arguments.contains("--uitest-keep-toolbar-pref") {
            store.terminalToolbar.clearExplicitChoice()
        }

        // Same for the app-global terminal font size: back to the 14pt
        // default unless the test deliberately exercises persistence.
        if !arguments.contains("--uitest-keep-font-pref") {
            store.terminalFont.reset()
        }

        // Same for the app-global appearance preference: back to System
        // unless the test deliberately exercises persistence.
        if !arguments.contains("--uitest-keep-theme-pref") {
            store.theme.reset()
        }
        if !arguments.contains("--uitest-keep-margin-pref") {
            store.terminalMargin.setMargin(.small)
        }

        let command = TerminalSceneUITest.value(after: "--uitest-session-command")
        let names = TerminalSceneUITest.values(after: "--uitest-open-session")
        for name in names {
            await openAndCommand(store: store, name: name, command: command, present: present)
        }

        for name in TerminalSceneUITest.values(after: "--uitest-open-session-detached") {
            await openDetachedAndCommand(store: store, name: name, command: command)
        }

        if let later = TerminalSceneUITest.value(after: "--uitest-open-session-after") {
            let parts = later.split(separator: ":").map(String.init)
            guard parts.count == 2, let delay = Double(parts[1]) else { return }
            try? await Task.sleep(for: .seconds(delay))
            await openAndCommand(store: store, name: parts[0], command: command, present: present)
        }
    }

    @MainActor
    private static func openAndCommand(
        store: SessionStore,
        name: String,
        command: String?,
        present: @MainActor (SessionStore.SessionDescriptor) -> Void
    ) async {
        guard let connection = await connection(named: name) else { return }
        let descriptor = store.openSession(for: connection)
        present(descriptor)
        guard await store.waitUntilActive(descriptor.id, timeout: 45) else { return }
        if let command {
            let resolved = command.replacingOccurrences(of: "{NAME}", with: name)
            try? await store.registry.send(
                sceneID: descriptor.registrySceneID,
                Data((resolved + "\n").utf8)
            )
        }
    }

    /// Detached open: no presentation — the session runs with no surface so
    /// switcher tests can attach it on demand. The scene model is started
    /// directly (no view will fire `.task { model.start() }` for it yet).
    @MainActor
    private static func openDetachedAndCommand(
        store: SessionStore,
        name: String,
        command: String?
    ) async {
        guard let connection = await connection(named: name) else { return }
        let descriptor = store.openSession(for: connection)
        guard let model = store.sceneModel(for: descriptor.id) else { return }
        await model.start()
        guard await store.waitUntilActive(descriptor.id, timeout: 45) else { return }
        if let command {
            let resolved = command.replacingOccurrences(of: "{NAME}", with: name)
            try? await store.registry.send(
                sceneID: descriptor.registrySceneID,
                Data((resolved + "\n").utf8)
            )
        }
    }

    /// The seeding hook runs inside ConnectionsModel bootstrap, which races
    /// this driver — poll until the named connection is durably listed.
    private static func connection(named name: String) async -> Connection? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let connections = (try? await AppServices.shared.connectionStore.loadConnections()) ?? []
            if let match = connections.first(where: { $0.name == name }) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}

/// Seeds the two loopback fixture connections (Alpha on hop1, Beta on hop2)
/// the session-scene UI tests connect to. Idempotent; requires the fixture
/// keys to have been imported (`--uitest-seed-keys`).
enum SessionFixtureSeeder {
    @MainActor
    static func seedIfNeeded() async {
        guard TerminalSceneUITest.seamsEnabled else { return }
        let store = AppServices.shared.connectionStore
        let existing = (try? await store.loadConnections()) ?? []
        let keys = (try? await AppServices.shared.keyRepository.list()) ?? []
        let keyReference = keys.first { $0.label == "Fixture Ed25519" }?.reference
            ?? keys.first?.reference ?? "seed-key-missing"

        for (name, port) in [("Alpha", 12222), ("Beta", 12223)] {
            guard !existing.contains(where: { $0.name == name }) else { continue }
            guard let connection = try? Connection(
                name: name,
                type: .ssh,
                host: "127.0.0.1",
                port: port,
                username: fixtureUsername(),
            customKeys: [keyReference]
            ) else { continue }
            try? await store.save(connection)
        }
    }

    /// The fixture sshd runs as the host user owning this checkout; the
    /// simulator app process resolves NSUserName() to "" (the same gap the
    /// core tests work around), so derive the name from `#filePath`.
    static func fixtureUsername() -> String {
        for candidate in [ProcessInfo.processInfo.environment["USER"],
                          ProcessInfo.processInfo.environment["LOGNAME"]] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        let components = URL(fileURLWithPath: #filePath).pathComponents
        if components.count > 3, components[0] == "/", components[1] == "Users" {
            return components[2]
        }
        return NSUserName()
    }
}
#endif
