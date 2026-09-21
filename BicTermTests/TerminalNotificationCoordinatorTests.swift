import BicTermCore
import SwiftTerm
import SwiftUI
import UIKit
import UserNotifications
import XCTest
@testable import BicTerm

/// OSC 777 notify routing and visible BEL — the app-side behavior added
/// on top of SwiftTerm's public `registerOscHandler(code: 777)`:
/// payload parsing (semicolons preserved in the body, malformed and
/// non-`notify` payloads rejected), local-notification sanitization,
/// per-scene banner lifecycle (replacement, isolation, manual + timed
/// dismissal, stale-timer safety), inactive-app coalesced posting, and
/// the `.soundAndVisual` bell applied at BOTH terminal creation sites.
@MainActor
final class TerminalNotificationCoordinatorTests: XCTestCase {
    // MARK: - Test doubles

    @MainActor
    private final class PosterSpy: TerminalNotificationPosting {
        private(set) var requests: [UNNotificationRequest] = []

        func post(_ request: UNNotificationRequest) {
            requests.append(request)
        }
    }

    private func makeCoordinator(
        active: Bool = true,
        poster: PosterSpy = PosterSpy(),
        bannerLifetime: TimeInterval = 5,
        cooldown: TimeInterval = 5
    ) -> (coordinator: TerminalNotificationCoordinator, poster: PosterSpy) {
        let coordinator = TerminalNotificationCoordinator(
            poster: poster,
            isAppActive: { active },
            bannerLifetime: bannerLifetime,
            localPostCooldown: cooldown
        )
        return (coordinator, poster)
    }

    private func payload(_ text: String) -> ArraySlice<UInt8> {
        Array(text.utf8)[...]
    }

    /// The full wire sequence for code 777, as the surface feed delivers it.
    private func osc777Bytes(_ payloadText: String) -> [UInt8] {
        Array("\u{1b}]777;\(payloadText)\u{07}".utf8)
    }

    // MARK: - Parser

    func testParserExtractsTitleAndBody() {
        let parsed = TerminalNotificationParser.parse(payload("notify;Build finished;done"))
        XCTAssertEqual(parsed?.title, "Build finished")
        XCTAssertEqual(parsed?.body, "done")
    }

    func testParserPreservesSemicolonsInBody() {
        let parsed = TerminalNotificationParser.parse(payload("notify;Deploy;a;b;c"))
        XCTAssertEqual(parsed?.title, "Deploy")
        XCTAssertEqual(parsed?.body, "a;b;c", "semicolons in the body must be preserved verbatim")
    }

    func testParserRejectsNonNotifyPayload() {
        XCTAssertNil(TerminalNotificationParser.parse(payload("growl;Title;Body")))
        XCTAssertNil(TerminalNotificationParser.parse(payload("notifyx;Title;Body")))
    }

    func testParserRejectsTooFewParts() {
        XCTAssertNil(TerminalNotificationParser.parse(payload("")))
        XCTAssertNil(TerminalNotificationParser.parse(payload("notify")))
        XCTAssertNil(TerminalNotificationParser.parse(payload("notify;only-a-title")))
    }

    func testParserRejectsInvalidUTF8() {
        XCTAssertNil(TerminalNotificationParser.parse([0xFF, 0xFE, 0x80][...]))
    }

    // MARK: - Sanitizer

    func testSanitizerConvertsLineBreaksToSpaces() {
        XCTAssertEqual(
            TerminalNotificationSanitizer.sanitize("line1\nline2\r\nline3\u{2028}end", limit: 60),
            "line1 line2 line3 end"
        )
    }

    func testSanitizerDropsControlAndFormatScalars() {
        // ESC (Cc) and zero-width space (Cf) are dropped; text survives.
        XCTAssertEqual(
            TerminalNotificationSanitizer.sanitize("a\u{1b}b\u{200b}c", limit: 60),
            "abc"
        )
    }

    func testSanitizerCollapsesWhitespaceRunsAndTrims() {
        XCTAssertEqual(
            TerminalNotificationSanitizer.sanitize("  a   b  ", limit: 60),
            "a b"
        )
    }

    func testSanitizerTruncatesByGraphemeCluster() {
        let long = String(repeating: "x", count: 70)
        let truncated = TerminalNotificationSanitizer.sanitize(long, limit: 60)
        XCTAssertEqual(truncated.count, 60)

        // A flag emoji is ONE grapheme cluster (two regional-indicator
        // scalars): truncation must count clusters, not scalars.
        let flags = String(repeating: "🇺🇸", count: 70)
        let truncatedFlags = TerminalNotificationSanitizer.sanitize(flags, limit: 60)
        XCTAssertEqual(truncatedFlags.count, 60)
    }

    // MARK: - Foreground routing

    func testForegroundPublishesBannerWithoutSystemRequest() {
        let (coordinator, poster) = makeCoordinator(active: true)
        coordinator.handle(payload: payload("notify;Build finished;done"), sceneID: "scene-a")

        let banner = coordinator.banner(for: "scene-a")
        XCTAssertEqual(banner?.title, "Build finished")
        XCTAssertEqual(banner?.body, "done")
        XCTAssertEqual(poster.requests.count, 0, "a foreground event must not post a system notification")
    }

    func testForegroundMalformedPayloadIsIgnored() {
        let (coordinator, poster) = makeCoordinator(active: true)
        coordinator.handle(payload: payload("notify"), sceneID: "scene-a")
        coordinator.handle(payload: payload("growl;t;b"), sceneID: "scene-a")

        XCTAssertNil(coordinator.banner(for: "scene-a"))
        XCTAssertEqual(poster.requests.count, 0)
    }

    // MARK: - Inactive routing

    func testInactivePostsOneSanitizedCoalescedRequest() {
        let (coordinator, poster) = makeCoordinator(active: false)
        coordinator.handle(payload: payload("notify;Build\ndone;ok\u{1b}"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Second;event"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Third;event"), sceneID: "scene-a")

        XCTAssertEqual(poster.requests.count, 1, "events within the cooldown must coalesce to one post")
        let request = poster.requests.first
        XCTAssertEqual(request?.content.title, "Build done", "line breaks must become spaces")
        XCTAssertEqual(request?.content.body, "ok", "control scalars must be dropped")
        XCTAssertNil(coordinator.banner(for: "scene-a"), "an inactive event must not publish a banner")
    }

    func testInactiveCooldownExpiryAllowsNextPost() async {
        let (coordinator, poster) = makeCoordinator(active: false, cooldown: 0.3)
        coordinator.handle(payload: payload("notify;First;one"), sceneID: "scene-a")
        try? await Task.sleep(for: .milliseconds(450))
        coordinator.handle(payload: payload("notify;Second;two"), sceneID: "scene-a")

        XCTAssertEqual(poster.requests.count, 2, "an event after the cooldown window must post again")
        XCTAssertEqual(poster.requests.last?.content.title, "Second")
    }

    // MARK: - Scene isolation and replacement

    func testTwoScenesNeverClobberEachOther() {
        let (coordinator, _) = makeCoordinator(active: true)
        coordinator.handle(payload: payload("notify;Alpha title;alpha"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Beta title;beta"), sceneID: "scene-b")

        XCTAssertEqual(coordinator.banner(for: "scene-a")?.title, "Alpha title")
        XCTAssertEqual(coordinator.banner(for: "scene-b")?.title, "Beta title")
    }

    func testReplacementOnlyWithinSameScene() {
        let (coordinator, _) = makeCoordinator(active: true)
        coordinator.handle(payload: payload("notify;First;one"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Second;two"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Other;other"), sceneID: "scene-b")

        XCTAssertEqual(coordinator.banner(for: "scene-a")?.title, "Second", "a new event replaces only its own scene's banner")
        XCTAssertEqual(coordinator.banner(for: "scene-b")?.title, "Other")
    }

    // MARK: - Dismissal

    func testManualDismissClearsBanner() {
        let (coordinator, _) = makeCoordinator(active: true)
        coordinator.handle(payload: payload("notify;Title;body"), sceneID: "scene-a")
        XCTAssertNotNil(coordinator.banner(for: "scene-a"))

        coordinator.dismissBanner(for: "scene-a")
        XCTAssertNil(coordinator.banner(for: "scene-a"))
    }

    func testTimedDismissClearsBannerAfterLifetime() async {
        let (coordinator, _) = makeCoordinator(active: true, bannerLifetime: 0.3)
        coordinator.handle(payload: payload("notify;Title;body"), sceneID: "scene-a")
        XCTAssertNotNil(coordinator.banner(for: "scene-a"))

        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(coordinator.banner(for: "scene-a"), "the banner must auto-dismiss after its lifetime")
    }

    func testStaleTimerDoesNotClearNewerBanner() async {
        let (coordinator, _) = makeCoordinator(active: true, bannerLifetime: 1.0)
        coordinator.handle(payload: payload("notify;First;one"), sceneID: "scene-a")
        try? await Task.sleep(for: .milliseconds(500))
        coordinator.handle(payload: payload("notify;Second;two"), sceneID: "scene-a")

        // At t≈1.2s the FIRST banner's timer (armed at t0, firing t0+1.0)
        // has fired; the replacement (armed t0+0.5, firing t0+1.5) must
        // still be up.
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(
            coordinator.banner(for: "scene-a")?.title,
            "Second",
            "a stale timer must never clear a newer banner"
        )

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(coordinator.banner(for: "scene-a"), "the replacement's own timer must still dismiss it")
    }

    func testGenerationGuardRejectsStaleClear() {
        let (coordinator, _) = makeCoordinator(active: true, bannerLifetime: 60)
        coordinator.handle(payload: payload("notify;First;one"), sceneID: "scene-a")
        coordinator.handle(payload: payload("notify;Second;two"), sceneID: "scene-a")

        coordinator.clearBannerIfCurrent(sceneID: "scene-a", generation: 1)
        XCTAssertEqual(coordinator.banner(for: "scene-a")?.title, "Second", "a stale generation's clear must no-op")

        coordinator.clearBannerIfCurrent(sceneID: "scene-a", generation: 2)
        XCTAssertNil(coordinator.banner(for: "scene-a"), "the current generation's clear must take effect")
    }

    // MARK: - Factories (both SSH terminal creation sites)

    private func makeAttachedSurface(
        coordinator: TerminalNotificationCoordinator? = nil
    ) throws -> (store: SessionStore, sceneID: String, surface: TerminalSurface) {
        let store = SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        if let coordinator {
            store.viewCache.notificationCoordinator = coordinator
        }
        let connection = try Connection(
            name: "NotifyCheck",
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
        let descriptor = store.openSession(for: connection)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        let attachment = store.viewCache.attachSurface(for: descriptor.id, model: model)
        return (store, descriptor.registrySceneID, attachment.surface)
    }

    func testCacheFactoryAppliesSoundAndVisualBell() throws {
        let (_, _, surface) = try makeAttachedSurface()
        XCTAssertEqual(
            surface.view.bellStyle,
            .soundAndVisual,
            "the session-cache terminal factory must apply the visible bell"
        )
    }

    func testCacheFactoryRoutesOsc777ThroughRegisteredHandler() throws {
        let (coordinator, _) = makeCoordinator(active: true)
        let (_, sceneID, surface) = try makeAttachedSurface(coordinator: coordinator)

        surface.view.feed(byteArray: osc777Bytes("notify;Build finished;done")[...])

        let banner = coordinator.banner(for: sceneID)
        XCTAssertEqual(banner?.title, "Build finished")
        XCTAssertEqual(banner?.body, "done")
    }

    func testCacheFactoryIgnoresMalformedOsc777() throws {
        let (coordinator, _) = makeCoordinator(active: true)
        let (_, sceneID, surface) = try makeAttachedSurface(coordinator: coordinator)

        surface.view.feed(byteArray: osc777Bytes("notify")[...])
        surface.view.feed(byteArray: osc777Bytes("growl;t;b")[...])

        XCTAssertNil(coordinator.banner(for: sceneID))
    }

    private func firstTerminalView(in view: UIView) -> TerminalContainerView? {
        if let terminal = view as? TerminalContainerView { return terminal }
        for subview in view.subviews {
            if let found = firstTerminalView(in: subview) { return found }
        }
        return nil
    }

    /// Hosts a `TerminalRepresentable` in a real window so its
    /// `makeUIView` factory runs, then returns the produced terminal view.
    private func hostRepresentable(
        _ representable: TerminalRepresentable
    ) throws -> TerminalContainerView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let hosting = UIHostingController(rootView: representable)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        if firstTerminalView(in: hosting.view) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            hosting.view.layoutIfNeeded()
        }
        return try XCTUnwrap(
            firstTerminalView(in: hosting.view),
            "the hosted TerminalRepresentable must produce a TerminalContainerView"
        )
    }

    func testRepresentableFactoryAppliesSoundAndVisualBell() throws {
        let terminal = try hostRepresentable(
            TerminalRepresentable(output: nil, send: { _ in }, onResize: { _, _ in })
        )
        XCTAssertEqual(
            terminal.bellStyle,
            .soundAndVisual,
            "the standalone terminal factory must apply the visible bell"
        )
    }

    func testRepresentableFactoryRoutesOsc777WhenCoordinatorProvided() throws {
        let (coordinator, _) = makeCoordinator(active: true)
        let terminal = try hostRepresentable(
            TerminalRepresentable(
                output: nil,
                send: { _ in },
                onResize: { _, _ in },
                notificationCoordinator: coordinator,
                notificationSceneID: "scene-preview"
            )
        )

        terminal.feed(byteArray: osc777Bytes("notify;Preview;hello")[...])

        XCTAssertEqual(coordinator.banner(for: "scene-preview")?.title, "Preview")
        XCTAssertEqual(coordinator.banner(for: "scene-preview")?.body, "hello")
    }
}
