import BicTermCore
import XCTest
@testable import BicTerm

/// Plan todo 9 (C5): focused iPad keyboard commands. Model-level coverage
/// for the command surface — focused-scene target resolution, next/previous
/// wraparound, close routing through the EXISTING confirmation (never a
/// direct teardown), Settings opening without stealing the focused target,
/// and no cross-scene leakage when a non-terminal scene (Settings, herdr)
/// holds focus. The hardware-chord registration itself (Cmd+N/W/]/[/,) is
/// SwiftUI `Commands` and cannot be synthesized by XCUITest on the
/// simulator; these tests pin the routing every chord dispatches through.
@MainActor
final class TerminalCommandsTests: XCTestCase {
    private func makeConnection(name: String) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
    }

    private func makeStore(connections: [Connection] = []) -> SessionStore {
        let byID = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        return SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { id in byID[id] }
        )
    }

    /// A target whose closures record every call, so routing tests can
    /// assert exactly which window-level action a command performed.
    /// MainActor-isolated like the closures it feeds (Swift 6: a
    /// @MainActor closure may not capture a non-isolated class).
    @MainActor
    private final class RecordingTarget {
        private(set) var connectionListRequests = 0
        private(set) var settingsRequests = 0
        private(set) var switchedTo: [UUID] = []

        var target: TerminalCommandTarget {
            TerminalCommandTarget(
                presentConnectionList: { self.connectionListRequests += 1 },
                switchToSession: { self.switchedTo.append($0) },
                presentSettings: { self.settingsRequests += 1 }
            )
        }
    }

    private func waitFor(
        _ model: SessionSceneModel,
        timeout: TimeInterval = 5,
        matching predicate: (SessionState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.state) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(model.state)
    }

    // MARK: - Focused-scene target resolution

    /// The focused target follows the ACTIVE terminal scene: a newly
    /// active window replaces the focused target, and a window going
    /// inactive only clears the target when IT holds it (activation can
    /// land before the previous window's deactivation).
    func testFocusedTargetResolutionTracksActiveTerminalScene() throws {
        let store = makeStore()
        let alpha = store.openSession(for: try makeConnection(name: "Alpha"))
        let beta = store.openSession(for: try makeConnection(name: "Beta"))
        let targetA = RecordingTarget()
        let targetB = RecordingTarget()

        // Window A becomes active.
        store.terminalCommands.noteFocusedTerminalScene(sessionID: alpha.id, target: targetA.target)
        XCTAssertEqual(store.terminalCommands.focusedSessionID, alpha.id)

        // Window B takes focus (B activates before A deactivates).
        store.terminalCommands.noteFocusedTerminalScene(sessionID: beta.id, target: targetB.target)
        XCTAssertEqual(store.terminalCommands.focusedSessionID, beta.id)

        // A's late deactivation must NOT clear B's focus.
        store.terminalCommands.noteTerminalSceneUnfocused(sessionID: alpha.id)
        XCTAssertEqual(store.terminalCommands.focusedSessionID, beta.id)

        // B deactivating (focus moved to a non-terminal scene) clears it.
        store.terminalCommands.noteTerminalSceneUnfocused(sessionID: beta.id)
        XCTAssertNil(store.terminalCommands.focusedSessionID)
    }

    /// The deactivate-first ordering (A backgrounds before B activates)
    /// also converges on the newly active scene.
    func testDeactivationBeforeActivationStillConvergesOnNewScene() throws {
        let store = makeStore()
        let alpha = store.openSession(for: try makeConnection(name: "Alpha"))
        let beta = store.openSession(for: try makeConnection(name: "Beta"))
        let target = RecordingTarget()

        store.terminalCommands.noteFocusedTerminalScene(sessionID: alpha.id, target: target.target)
        store.terminalCommands.noteTerminalSceneUnfocused(sessionID: alpha.id)
        XCTAssertNil(store.terminalCommands.focusedSessionID)

        store.terminalCommands.noteFocusedTerminalScene(sessionID: beta.id, target: target.target)
        XCTAssertEqual(store.terminalCommands.focusedSessionID, beta.id)
    }

    /// Closing the focused session (the store's single teardown path)
    /// clears the focused target — commands never act on a dead target.
    func testSessionCloseClearsFocusedTarget() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(connections: [alpha])
        let descriptor = store.openSession(for: alpha)
        let target = RecordingTarget()

        store.terminalCommands.noteFocusedTerminalScene(sessionID: descriptor.id, target: target.target)
        XCTAssertEqual(store.terminalCommands.focusedSessionID, descriptor.id)

        await store.closeScene(descriptor.id)
        XCTAssertNil(store.terminalCommands.focusedSessionID, "closeScene must retire the focused target")
    }

    // MARK: - Close routes through the existing confirmation

    /// Cmd+W routes the FOCUSED session through `requestClose` — the same
    /// confirmation guard the scene's Close button uses — and performs no
    /// teardown of its own: the session stays open until the user confirms.
    func testCloseCommandRoutesToConfirmationNotTeardown() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let store = makeStore(connections: [alpha, beta])
        let alphaDescriptor = store.openSession(for: alpha)
        let betaDescriptor = store.openSession(for: beta)
        let alphaModel = try XCTUnwrap(store.sceneModel(for: alphaDescriptor.id))
        let betaModel = try XCTUnwrap(store.sceneModel(for: betaDescriptor.id))
        await alphaModel.start()
        await betaModel.start()
        let alphaActive = await waitFor(alphaModel) { $0 == .active }
        let betaActive = await waitFor(betaModel) { $0 == .active }
        XCTAssertTrue(alphaActive && betaActive)

        // Beta's window is the focused terminal scene.
        store.terminalCommands.noteFocusedTerminalScene(
            sessionID: betaDescriptor.id, target: RecordingTarget().target)

        store.performTerminalCommand(.closeSession)

        XCTAssertTrue(betaModel.pendingCloseConfirmation, "close must arm the existing confirmation")
        XCTAssertFalse(betaModel.isClosed, "close must never tear the session down directly")
        XCTAssertNotNil(store.descriptor(id: betaDescriptor.id), "the session must survive the command")
        let registryState = await store.registry.state(sceneID: betaModel.sceneID)
        XCTAssertNotNil(registryState, "the registry session must survive the command")

        // No cross-scene leakage: the unfocused session is untouched.
        XCTAssertFalse(alphaModel.pendingCloseConfirmation)
        XCTAssertFalse(alphaModel.isClosed)
    }

    /// With no focused terminal scene (a Settings or herdr window holds
    /// focus), the close command is a strict no-op — those scenes keep
    /// their own close/dismiss behavior.
    func testCloseCommandNoOpsWithoutFocusedTerminalScene() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(connections: [alpha])
        let descriptor = store.openSession(for: alpha)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()
        let active = await waitFor(model) { $0 == .active }
        XCTAssertTrue(active)

        store.performTerminalCommand(.closeSession)

        XCTAssertFalse(model.pendingCloseConfirmation, "no terminal scene may receive the action")
        XCTAssertFalse(model.isClosed)
        XCTAssertNotNil(store.descriptor(id: descriptor.id))
    }

    // MARK: - New Session / Settings routing

    /// New Session and Settings route to the FOCUSED window's target —
    /// and only that target. Settings opens without stealing the focused
    /// session: no close confirmation, no switch, focus unchanged.
    func testNewSessionAndSettingsRouteToFocusedTargetWithoutStealingFocus() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(connections: [alpha])
        let descriptor = store.openSession(for: alpha)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()
        _ = await waitFor(model) { $0 == .active }

        let target = RecordingTarget()
        store.terminalCommands.noteFocusedTerminalScene(sessionID: descriptor.id, target: target.target)

        store.performTerminalCommand(.newSession)
        XCTAssertEqual(target.connectionListRequests, 1, "New Session must present the connection list")
        XCTAssertEqual(target.settingsRequests, 0)
        XCTAssertTrue(target.switchedTo.isEmpty)

        store.performTerminalCommand(.settings)
        XCTAssertEqual(target.settingsRequests, 1, "Settings must present through the focused target")
        XCTAssertEqual(target.connectionListRequests, 1, "Settings must not re-trigger New Session")

        // Settings opened without stealing the focused terminal session.
        XCTAssertEqual(store.terminalCommands.focusedSessionID, descriptor.id)
        XCTAssertFalse(model.pendingCloseConfirmation, "Settings must never close anything")
        XCTAssertFalse(model.isClosed)
        XCTAssertTrue(target.switchedTo.isEmpty, "Settings must never switch sessions")
    }

    /// Without a focused terminal scene, New Session and Settings are
    /// no-ops (Settings and herdr scenes never receive terminal actions).
    func testNewSessionAndSettingsNoOpWithoutFocusedTerminalScene() {
        let store = makeStore()
        let target = RecordingTarget()
        // A previously focused window went inactive without a successor.
        store.terminalCommands.noteTerminalSceneUnfocused(sessionID: UUID())

        store.performTerminalCommand(.newSession)
        store.performTerminalCommand(.settings)

        XCTAssertEqual(target.connectionListRequests, 0)
        XCTAssertEqual(target.settingsRequests, 0)
    }

    // MARK: - Next / Previous wraparound

    /// Next/Previous resolve the neighboring live session in opening
    /// order, WRAPPING AROUND at both ends; a lone session has no
    /// neighbor.
    func testNextAndPreviousNeighborResolutionWrapsAround() throws {
        let store = makeStore()
        let alpha = store.openSession(for: try makeConnection(name: "Alpha"))
        let beta = store.openSession(for: try makeConnection(name: "Beta"))
        let gamma = store.openSession(for: try makeConnection(name: "Gamma"))

        XCTAssertEqual(store.neighboringTerminalSession(of: beta.id, forward: true), gamma.id)
        XCTAssertEqual(store.neighboringTerminalSession(of: beta.id, forward: false), alpha.id)
        // Wraparound at both ends.
        XCTAssertEqual(store.neighboringTerminalSession(of: gamma.id, forward: true), alpha.id)
        XCTAssertEqual(store.neighboringTerminalSession(of: alpha.id, forward: false), gamma.id)
        // A session that is no longer live has no neighbor.
        XCTAssertNil(store.neighboringTerminalSession(of: UUID(), forward: true))

        // A lone session cycles to nothing.
        let lone = makeStore()
        let only = lone.openSession(for: try makeConnection(name: "Only"))
        XCTAssertNil(lone.neighboringTerminalSession(of: only.id, forward: true))
        XCTAssertNil(lone.neighboringTerminalSession(of: only.id, forward: false))
    }

    /// The switch command hands the resolved neighbor to the FOCUSED
    /// window's target (the same in-window/jump switch the session menu
    /// performs) — never to any other scene.
    func testSwitchCommandRoutesNeighborThroughFocusedTarget() throws {
        let store = makeStore()
        let alpha = store.openSession(for: try makeConnection(name: "Alpha"))
        let beta = store.openSession(for: try makeConnection(name: "Beta"))
        let gamma = store.openSession(for: try makeConnection(name: "Gamma"))
        let target = RecordingTarget()

        store.terminalCommands.noteFocusedTerminalScene(sessionID: beta.id, target: target.target)

        store.performTerminalCommand(.nextSession)
        store.performTerminalCommand(.previousSession)

        XCTAssertEqual(target.switchedTo, [gamma.id, alpha.id], "next then previous from Beta")
    }

    /// Switch commands with no focused terminal scene are no-ops.
    func testSwitchCommandNoOpsWithoutFocusedTerminalScene() throws {
        let store = makeStore()
        store.openSession(for: try makeConnection(name: "Alpha"))
        store.openSession(for: try makeConnection(name: "Beta"))
        let target = RecordingTarget()

        store.performTerminalCommand(.nextSession)
        store.performTerminalCommand(.previousSession)

        XCTAssertTrue(target.switchedTo.isEmpty)
    }
}
