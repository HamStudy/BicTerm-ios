import BicTermCore
import XCTest
@testable import BicTerm

@MainActor
final class SessionAppearanceTests: XCTestCase {
    private func makeStore() -> SessionStore {
        SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
    }

    func testResolutionResetAndLiveGlobalDefaults() {
        let store = makeStore()
        store.terminalFont.setSize(14)
        store.theme.setPreference(.dark)
        store.terminalMargin.setMargin(.small)
        store.setFontSize(18, sceneID: "A")
        store.setTheme(.system, sceneID: "A")
        store.setMargin(TerminalMargin.none, sceneID: "A")
        store.terminalFont.setSize(20)
        store.theme.setPreference(.light)
        store.terminalMargin.setMargin(.large)
        XCTAssertEqual(store.effectiveFontSize("A"), 18)
        XCTAssertEqual(store.effectiveTheme("A"), .system)
        XCTAssertEqual(store.effectiveMargin("A"), .none)
        XCTAssertEqual(store.effectiveFontSize("B"), 20)
        XCTAssertEqual(store.effectiveTheme("B"), .light)
        XCTAssertEqual(store.effectiveMargin("B"), .large)
        store.setFontSize(nil, sceneID: "A")
        store.setTheme(nil, sceneID: "A")
        store.setMargin(nil, sceneID: "A")
        XCTAssertEqual(store.effectiveFontSize("A"), 20)
        XCTAssertEqual(store.effectiveTheme("A"), .light)
        XCTAssertEqual(store.effectiveMargin("A"), .large)
    }

    func testScopedSurfaceFontPinchAndLifetime() async throws {
        let store = makeStore()
        store.terminalFont.setSize(14)
        let connection = try Connection(name: "test", type: .ssh, host: "localhost", port: 22,
                                        username: "test", keyReference: "test")
        let a = store.openSession(for: connection)
        let b = store.openSession(for: connection)
        let modelA = try XCTUnwrap(store.sceneModel(for: a.id))
        let modelB = try XCTUnwrap(store.sceneModel(for: b.id))
        let attachment = store.viewCache.attachSurface(for: a.id, model: modelA)
        let surfaceB = store.viewCache.attachSurface(for: b.id, model: modelB).surface
        attachment.surface.view.onFontPinch?(18)
        XCTAssertEqual(store.effectiveFontSize(a.registrySceneID), 18)
        XCTAssertEqual(store.terminalFont.size, 14)
        XCTAssertEqual(attachment.surface.view.font.pointSize, 18)
        XCTAssertEqual(surfaceB.view.font.pointSize, 14)
        store.viewCache.detachSurface(for: a.id, generation: attachment.generation)
        store.terminalFont.setSize(20)
        XCTAssertEqual(attachment.surface.view.font.pointSize, 18)
        XCTAssertEqual(surfaceB.view.font.pointSize, 20)
        let reattached = store.viewCache.attachSurface(for: a.id, model: modelA)
        XCTAssertTrue(reattached.surface === attachment.surface)
        XCTAssertEqual(reattached.surface.view.font.pointSize, 18)
        store.setFontSize(nil, sceneID: a.registrySceneID)
        XCTAssertEqual(reattached.surface.view.font.pointSize, 20)
        store.setFontSize(99, sceneID: a.registrySceneID)
        XCTAssertEqual(store.effectiveFontSize(a.registrySceneID), 32)
        XCTAssertTrue(makeStore().appearanceOverrides.isEmpty)
        await store.closeScene(a.id)
        XCTAssertNil(store.appearanceOverrides[a.registrySceneID])
        await store.closeScene(b.id)
    }

    func testGlobalMarginsPersistIncludingZero() throws {
        let suite = "SessionAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TerminalMarginSettings(defaults: defaults)
        XCTAssertEqual(settings.margin, .small)
        let model = TerminalMarginModel(settings: settings)
        model.setMargin(.none)
        XCTAssertEqual(TerminalMarginModel(settings: settings).margin, .none)
        model.setMargin(.large)
        XCTAssertEqual(TerminalMarginModel(settings: settings).margin, .large)
    }
}
