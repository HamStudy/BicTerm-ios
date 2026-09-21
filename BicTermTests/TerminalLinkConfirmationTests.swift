import BicTermCore
import SwiftTerm
import UIKit
import XCTest
@testable import BicTerm

/// Link confirmation — the app-side behavior on top of the fork's
/// touch-type-aware activation (hunk 13) and semicolon-safe OSC 8
/// parsing (hunk 14): the scheme policy (only valid http/https URLs are
/// openable), immutable request value semantics, the scene model's
/// present/cancel/confirm lifecycle (the opener runs ONLY after
/// explicit confirmation of a policy-approved URL), and both SSH
/// surface delegates forwarding taps into scene state.
@MainActor
final class TerminalLinkConfirmationTests: XCTestCase {
    // MARK: - Scheme policy

    func testPolicyAllowsHttpAndHttps() {
        for link in ["http://example.com", "https://example.com/a;b", "HTTPS://example.com/x"] {
            let decision = TerminalLinkPolicy.evaluate(link)
            XCTAssertTrue(decision.canOpen, link)
            XCTAssertEqual(decision.host, "example.com", link)
        }
    }

    func testPolicyDeniesNonHttpSchemes() {
        for link in [
            "file:///etc/passwd",
            "ssh://user@host",
            "mailto:someone@example.com",
            "javascript:alert(1)",
            "ftp://example.com",
            "gopher://example.com",
        ] {
            XCTAssertFalse(TerminalLinkPolicy.evaluate(link).canOpen, link)
        }
    }

    func testPolicyDeniesUnparseableRelativeAndHostlessLinks() {
        for link in ["example.com/x", "not a url", "https://", "http://"] {
            XCTAssertFalse(TerminalLinkPolicy.evaluate(link).canOpen, link)
        }
    }

    func testPolicyExtractsHost() {
        XCTAssertEqual(TerminalLinkPolicy.evaluate("https://example.com:8080/a;b").host, "example.com")
        XCTAssertEqual(TerminalLinkPolicy.evaluate("http://localhost/x").host, "localhost")
        XCTAssertNil(TerminalLinkPolicy.evaluate("file:///etc/passwd").host)
    }

    // MARK: - Immutable request

    func testRequestCapturesParamsByValue() {
        var params = ["id": "original"]
        let request = TerminalLinkRequest(link: "https://example.com", params: params)
        params["id"] = "mutated"
        XCTAssertEqual(request.params, ["id": "original"], "params must be captured by value")

        var source = ["k": "v"]
        let other = TerminalLinkRequest(link: "https://example.com", params: source)
        source["k"] = "changed"
        XCTAssertEqual(other.params, ["k": "v"])
        XCTAssertNotEqual(request.id, other.id, "each request carries a fresh identity")
    }

    // MARK: - Scene model lifecycle

    private func makeModel(name: String = "Alpha") throws -> SessionSceneModel {
        let store = SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        let connection = try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
        let descriptor = store.openSession(for: connection)
        return try XCTUnwrap(store.sceneModel(for: descriptor.id))
    }

    func testPresentAndCancelLinkConfirmation() throws {
        let model = try makeModel()
        XCTAssertNil(model.pendingLinkRequest)

        let request = TerminalLinkRequest(link: "https://example.com/a;b", params: ["id": "x"])
        model.presentLinkConfirmation(request)
        XCTAssertEqual(model.pendingLinkRequest, request)

        model.cancelLinkConfirmation()
        XCTAssertNil(model.pendingLinkRequest)
    }

    func testCapturedRequestIsStableAcrossLaterPresents() throws {
        let model = try makeModel()
        let first = TerminalLinkRequest(link: "https://a.example", params: [:])
        model.presentLinkConfirmation(first)
        let captured = model.pendingLinkRequest
        model.presentLinkConfirmation(TerminalLinkRequest(link: "https://b.example", params: [:]))
        XCTAssertEqual(captured, first, "a captured request is a value — later presents cannot mutate it")
    }

    func testConfirmOpensPolicyApprovedUrlThroughInjectedOpener() throws {
        let model = try makeModel()
        var opened: [URL] = []
        model.linkOpener = { opened.append($0) }

        model.presentLinkConfirmation(TerminalLinkRequest(link: "https://example.com/a;b", params: [:]))
        model.confirmLinkOpen()

        XCTAssertEqual(opened, [URL(string: "https://example.com/a;b")!])
        XCTAssertNil(model.pendingLinkRequest, "confirmation consumes the request")
    }

    func testConfirmNeverOpensNonHttpLink() throws {
        let model = try makeModel()
        var opened: [URL] = []
        model.linkOpener = { opened.append($0) }

        model.presentLinkConfirmation(TerminalLinkRequest(link: "file:///etc/passwd", params: [:]))
        model.confirmLinkOpen()

        XCTAssertTrue(opened.isEmpty, "a file:// link must never reach the opener")
        XCTAssertNil(model.pendingLinkRequest)
    }

    func testCancelNeverOpens() throws {
        let model = try makeModel()
        var opened: [URL] = []
        model.linkOpener = { opened.append($0) }

        model.presentLinkConfirmation(TerminalLinkRequest(link: "https://example.com", params: [:]))
        model.cancelLinkConfirmation()
        model.confirmLinkOpen()

        XCTAssertTrue(opened.isEmpty, "cancel must leave nothing to confirm")
    }

    func testConfirmWithoutPendingRequestIsNoOp() throws {
        let model = try makeModel()
        var opened: [URL] = []
        model.linkOpener = { opened.append($0) }

        model.confirmLinkOpen()

        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - SSH surface delegate forwarding

    private func makeAttachedSurface(name: String) throws -> (model: SessionSceneModel, surface: TerminalSurface) {
        let store = SessionStore(
            transportFactory: ScriptedSessionTransportFactory(fallback: .succeed),
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        let connection = try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
        let descriptor = store.openSession(for: connection)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        let attachment = store.viewCache.attachSurface(for: descriptor.id, model: model)
        return (model, attachment.surface)
    }

    func testSurfaceDelegateForwardsImmutableRequestIntoSceneState() throws {
        let (model, surface) = try makeAttachedSurface(name: "Alpha")
        XCTAssertNil(model.pendingLinkRequest)

        surface.requestOpenLink(
            source: surface.view,
            link: "https://example.com/a;b",
            params: ["id": "example"]
        )

        let request = try XCTUnwrap(model.pendingLinkRequest)
        XCTAssertEqual(request.link, "https://example.com/a;b")
        XCTAssertEqual(request.params, ["id": "example"])
    }

    func testStandaloneCoordinatorForwardsRequestThroughPresenterHook() {
        var received: [TerminalLinkRequest] = []
        let representable = TerminalRepresentable(
            output: nil,
            send: { _ in },
            onResize: { _, _ in },
            linkPresenter: { received.append($0) }
        )
        let coordinator = TerminalCoordinator(parent: representable)
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))

        coordinator.requestOpenLink(source: view, link: "https://example.com/x", params: ["id": "y"])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.link, "https://example.com/x")
        XCTAssertEqual(received.first?.params, ["id": "y"])
    }

    func testStandaloneCoordinatorWithoutPresenterOpensNothing() {
        let representable = TerminalRepresentable(
            output: nil,
            send: { _ in },
            onResize: { _, _ in }
        )
        let coordinator = TerminalCoordinator(parent: representable)
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))

        coordinator.requestOpenLink(source: view, link: "https://example.com/x", params: [:])
    }
}
