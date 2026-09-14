import BicTermCore
import XCTest
@testable import BicTerm

/// TerminalViewCache behavior: capacity bound, surface reuse (scrollback
/// preservation), detach-without-drop, and the eviction → re-attach notice.
@MainActor
final class TerminalViewCacheTests: XCTestCase {
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

    @discardableResult
    private func makeAttachedModel(
        store: SessionStore,
        name: String
    ) throws -> (model: SessionSceneModel, surface: TerminalSurface, generation: UInt64) {
        let connection = try makeConnection(name: name)
        let descriptor = store.openSession(for: connection)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        let attachment = store.viewCache.attachSurface(for: descriptor.id, model: model)
        return (model, attachment.surface, attachment.generation)
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
    }

    /// Plan T2 acceptance: a 12-session attach loop must leave at most 8
    /// live surfaces (DEBUG-seeded bound).
    func testTwelveSessionAttachLoopBoundsCacheToCapacityEight() throws {
        let store = makeStore()
        let first = try makeAttachedModel(store: store, name: "s1")
        var identifiers = [first.model.id]
        for index in 2...12 {
            identifiers.append(try makeAttachedModel(store: store, name: "s\(index)").model.id)
        }

        XCTAssertLessThanOrEqual(store.viewCache.cachedCount, 8)
        XCTAssertEqual(store.viewCache.cachedCount, 8)

        // The four least-recently-attached sessions were evicted: the first
        // session re-attaches to a FRESH surface and reports released
        // scrollback; the most recent one re-attaches its own surface.
        let firstAgain = store.viewCache.attachSurface(for: first.model.id, model: first.model).surface
        XCTAssertFalse(
            firstAgain === first.surface,
            "evicted session must re-attach a fresh surface"
        )
        XCTAssertTrue(first.model.scrollbackReleased, "evicted session must flag the notice on re-attach")
    }

    /// Re-attaching a cached session returns the SAME view instance — the
    /// in-memory scrollback survives switching away and back.
    func testReattachReturnsSameSurfaceInstance() throws {
        let store = makeStore()
        let attached = try makeAttachedModel(store: store, name: "Alpha")

        store.viewCache.detachSurface(for: attached.model.id, generation: attached.generation)
        XCTAssertEqual(store.viewCache.cachedCount, 1, "detach must keep the entry")

        let reattached = store.viewCache.attachSurface(for: attached.model.id, model: attached.model).surface
        XCTAssertTrue(reattached === attached.surface, "cached surface identity must be preserved")
        XCTAssertFalse(attached.model.scrollbackReleased)
    }

    /// Session close removes the surface entirely: the next attach builds a
    /// fresh one and shows the scrollback-released notice.
    func testRemoveSurfaceThenAttachCreatesFreshSurfaceWithNotice() throws {
        let store = makeStore()
        let attached = try makeAttachedModel(store: store, name: "Alpha")

        store.viewCache.removeSurface(for: attached.model.id)
        XCTAssertEqual(store.viewCache.cachedCount, 0)

        let reattached = store.viewCache.attachSurface(for: attached.model.id, model: attached.model).surface
        XCTAssertFalse(reattached === attached.surface)
        XCTAssertTrue(attached.model.scrollbackReleased)
    }

    /// A dismantle carrying a superseded generation must NOT report the
    /// session detached — a newer attach (the switcher attached the same
    /// session in another window) still owns the surface. The CURRENT
    /// generation's dismantle does report it.
    func testSupersededGenerationDismantleDoesNotReportDetached() async throws {
        let store = makeStore()
        let connection = try makeConnection(name: "Alpha")
        let descriptor = store.openSession(for: connection)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()

        let first = store.viewCache.attachSurface(for: descriptor.id, model: model)
        let second = store.viewCache.attachSurface(for: descriptor.id, model: model)

        store.viewCache.detachSurface(for: descriptor.id, generation: first.generation)
        let stillAttached = await waitForPresentation(
            store, sceneID: descriptor.registrySceneID, matching: { $0.isAttached }
        )
        XCTAssertTrue(stillAttached, "superseded dismantle must not report detach")

        store.viewCache.detachSurface(for: descriptor.id, generation: second.generation)
        let detached = await waitForPresentation(
            store, sceneID: descriptor.registrySceneID, matching: { !$0.isAttached }
        )
        XCTAssertTrue(detached, "current-generation dismantle must report detach")
    }

    private func waitForPresentation(
        _ store: SessionStore,
        sceneID: String,
        matching predicate: @Sendable (SessionPresentationState) -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = await store.registry.presentationState(sceneID: sceneID), predicate(state) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Pure LRU: re-attaching an old session protects it; the stale one is
    /// evicted when capacity is exceeded.
    func testRecencyProtectsRecentlyAttachedFromEviction() throws {
        let store = SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        let smallCache = TerminalViewCache(capacity: 2)
        let alpha = try makeAttachedModel(store: store, name: "Alpha")
        let beta = try makeAttachedModel(store: store, name: "Beta")

        _ = smallCache.attachSurface(for: alpha.model.id, model: alpha.model)
        _ = smallCache.attachSurface(for: beta.model.id, model: beta.model)
        _ = smallCache.attachSurface(for: alpha.model.id, model: alpha.model)

        let gamma = try makeAttachedModel(store: store, name: "Gamma")
        _ = smallCache.attachSurface(for: gamma.model.id, model: gamma.model)
        XCTAssertEqual(smallCache.cachedCount, 2)

        _ = smallCache.attachSurface(for: beta.model.id, model: beta.model)
        XCTAssertTrue(beta.model.scrollbackReleased, "stale entry (LRU) must be the evicted one")
        XCTAssertFalse(alpha.model.scrollbackReleased, "recently re-attached entry must survive")
        XCTAssertFalse(gamma.model.scrollbackReleased, "newest entry must survive")
    }

    /// Font-size live-apply: the store's `terminalFont` model is wired to
    /// the cache, so an applied change re-fonts every cached surface and
    /// newly attached surfaces start at the current size. (The store's
    /// model persists to `.standard`; reset before and after so simulator
    /// state can never leak between runs.)
    func testFontSizeChangeRefontsCachedAndNewSurfaces() throws {
        let store = makeStore()
        store.terminalFont.reset()
        defer { store.terminalFont.reset() }

        let alpha = try makeAttachedModel(store: store, name: "Alpha")
        let beta = try makeAttachedModel(store: store, name: "Beta")
        XCTAssertEqual(alpha.surface.view.font.pointSize, 14)
        XCTAssertEqual(beta.surface.view.font.pointSize, 14)

        store.terminalFont.setSize(20)
        XCTAssertEqual(alpha.surface.view.font.pointSize, 20, "attached surface must re-font live")
        XCTAssertEqual(beta.surface.view.font.pointSize, 20, "every cached surface must re-font")

        let gamma = try makeAttachedModel(store: store, name: "Gamma")
        XCTAssertEqual(gamma.surface.view.font.pointSize, 20, "new surfaces start at the current size")

        store.terminalFont.reset()
        XCTAssertEqual(alpha.surface.view.font.pointSize, 14, "reset must re-font back to default")
    }

    /// The switcher's stable listing: sessions appear in opening order and
    /// disappear on close.
    func testOrderedDescriptorsTrackOpenAndClose() async throws {
        let store = makeStore()
        let alpha = try makeAttachedModel(store: store, name: "Alpha")
        let beta = try makeAttachedModel(store: store, name: "Beta")
        XCTAssertEqual(store.orderedDescriptors.map(\.connection.name), ["Alpha", "Beta"])

        await store.closeScene(beta.model.id)
        XCTAssertEqual(store.orderedDescriptors.map(\.id), [alpha.model.id])
        XCTAssertEqual(store.viewCache.cachedCount, 1, "close must drop the surface")
    }
}
