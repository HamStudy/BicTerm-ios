import Foundation
import XCTest
@testable import BicTermCore

/// Presentation state for the session switcher (plan T2): which sessions
/// have a live terminal surface attached, and which detached sessions
/// received output the user has not seen yet. Pure presentation metadata —
/// no transport, lifecycle, or reconnection behavior may depend on it.
final class SessionPresentationStateTests: XCTestCase {
    private func makeRegistry(
        factory: FakeSessionTransportFactory = FakeSessionTransportFactory()
    ) -> SessionRegistry {
        SessionRegistry(transportFactory: factory, snapshotStore: InMemorySnapshotStore())
    }

    /// New sessions start detached with no unseen output.
    func testNewSessionStartsDetachedWithoutUnseenOutput() async throws {
        let registry = makeRegistry()
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "scene-a", connection: connection)

        let presentation = await registry.presentationState(sceneID: "scene-a")
        XCTAssertEqual(presentation, SessionPresentationState(isAttached: false, hasUnseenOutput: false))
    }

    /// Output bytes arriving while the session is detached mark unseen
    /// output; attaching clears the flag and marks the session attached.
    func testOutputWhileDetachedMarksUnseenUntilAttached() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "scene-a", connection: connection)
        let transport = factory.transports[0]

        await transport.yield(Data("detached output".utf8))

        let unseenSeen = await waitForUnseen(registry, sceneID: "scene-a", timeoutMilliseconds: 3000)
        XCTAssertTrue(unseenSeen, "detached session output must mark hasUnseenOutput")

        await registry.attached(sceneID: "scene-a")
        let attached = await registry.presentationState(sceneID: "scene-a")
        XCTAssertEqual(
            attached,
            SessionPresentationState(isAttached: true, hasUnseenOutput: false),
            "attaching must clear the unseen flag"
        )

        await registry.detached(sceneID: "scene-a")
        let detached = await registry.presentationState(sceneID: "scene-a")
        XCTAssertEqual(detached, SessionPresentationState(isAttached: false, hasUnseenOutput: false))
    }

    /// Output while a surface is attached never marks unseen output.
    func testOutputWhileAttachedDoesNotMarkUnseen() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "scene-a", connection: connection)
        let transport = factory.transports[0]

        await registry.attached(sceneID: "scene-a")
        await transport.yield(Data("live output".utf8))

        let presentation = await registry.presentationState(sceneID: "scene-a")
        XCTAssertEqual(
            presentation,
            SessionPresentationState(isAttached: true, hasUnseenOutput: false),
            "attached sessions must not accumulate unseen output"
        )
    }

    /// Presentation calls on unknown sessions are no-ops; the getter
    /// reports nil (the session is not live).
    func testUnknownSceneIDIsNoOpAndNil() async {
        let registry = makeRegistry()

        await registry.attached(sceneID: "missing")
        await registry.detached(sceneID: "missing")

        let presentation = await registry.presentationState(sceneID: "missing")
        XCTAssertNil(presentation)
    }

    /// Closing a session removes its presentation state with the record.
    func testClosedSessionHasNoPresentationState() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "scene-a", connection: connection)
        await registry.attached(sceneID: "scene-a")

        await registry.closeSession(sceneID: "scene-a")

        let presentation = await registry.presentationState(sceneID: "scene-a")
        XCTAssertNil(presentation)
    }

    private func waitForUnseen(
        _ registry: SessionRegistry,
        sceneID: String,
        timeoutMilliseconds: UInt64
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if let state = await registry.presentationState(sceneID: sceneID), state.hasUnseenOutput {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
