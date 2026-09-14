import BicTermCore
import XCTest
@testable import BicTerm

private struct AlwaysInteractive: LockStateProvider {
    var isInteractive: Bool { true }
}

private struct NeverInteractive: LockStateProvider {
    var isInteractive: Bool { false }
}

/// Behavioral coverage of the agent approval surface T14 wires to the T8
/// service: same-session caching for "approve for this session", fresh
/// prompts for other sessions, deny, and presentation routing to the
/// originating scene.
@MainActor
final class AgentApprovalFlowTests: XCTestCase {
    private func makePresenter() -> AgentApprovalPresenter {
        AgentApprovalPresenter(resolveRouting: { _ in
            AgentPromptRouting(target: .mainWindow, sessionDisplayName: "Session")
        })
    }

    private func waitUntilPending(
        _ presenter: AgentApprovalPresenter,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if presenter.pendingRequest != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return presenter.pendingRequest != nil
    }

    private func request(sessionID: String, fingerprint: String = "SHA256:abc123") -> AgentAuthorizationRequest {
        AgentAuthorizationRequest(
            sessionID: sessionID,
            host: "127.0.0.1",
            keyFingerprint: fingerprint,
            publicKeyBlob: Data([0x01, 0x02])
        )
    }

    func testAllowForSessionSuppressesSecondPromptOnlyWithinSameSession() async {
        let presenter = makePresenter()
        let service = AgentAuthorizationService(prompt: presenter, lockState: AlwaysInteractive())
        let sameSession = request(sessionID: "session-one")

        async let first: Bool = service.authorize(sameSession)
        let firstPending = await waitUntilPending(presenter)
        XCTAssertTrue(firstPending, "first request must surface the approval sheet")
        XCTAssertEqual(presenter.pendingRequest?.keyFingerprint, "SHA256:abc123")
        XCTAssertEqual(presenter.pendingRequest?.host, "127.0.0.1")
        presenter.resolve(.allowForSession)
        let firstAllowed = await first
        XCTAssertTrue(firstAllowed)

        async let second: Bool = service.authorize(sameSession)
        let secondAllowed = await second
        XCTAssertTrue(secondAllowed, "cached session approval must allow without a second prompt")
        XCTAssertNil(presenter.pendingRequest, "no second sheet may appear in the same session")
        XCTAssertEqual(presenter.promptCount, 1)

        let thirdRequest = request(sessionID: "session-two")
        async let third: Bool = service.authorize(thirdRequest)
        let thirdPending = await waitUntilPending(presenter)
        XCTAssertTrue(thirdPending, "a NEW session must prompt again")
        XCTAssertEqual(presenter.promptCount, 2)
        XCTAssertEqual(presenter.pendingRequest?.sessionID, "session-two")
        presenter.resolve(.deny)
        let denied = await third
        XCTAssertFalse(denied, "deny must fail the request")
    }

    func testDenyFailsTheRequestAndPromptsAgainOnTheNextRequest() async {
        let presenter = makePresenter()
        let service = AgentAuthorizationService(prompt: presenter, lockState: AlwaysInteractive())
        let session = request(sessionID: "session-one")

        async let first: Bool = service.authorize(session)
        let firstPending = await waitUntilPending(presenter)
        XCTAssertTrue(firstPending)
        presenter.resolve(.deny)
        let firstDenied = await first
        XCTAssertFalse(firstDenied)

        async let second: Bool = service.authorize(session)
        let secondPending = await waitUntilPending(presenter)
        XCTAssertTrue(secondPending, "deny must not be cached — the next request prompts again")
        XCTAssertEqual(presenter.promptCount, 2)
        presenter.resolve(.allowOnce)
        let secondAllowed = await second
        XCTAssertTrue(secondAllowed)
        XCTAssertEqual(presenter.promptCount, 2, "allowOnce must not prompt additional times for one request")
    }

    func testNonInteractiveStateDeniesWithoutPrompting() async {
        let presenter = makePresenter()
        let service = AgentAuthorizationService(prompt: presenter, lockState: NeverInteractive())
        let allowed = await service.authorize(request(sessionID: "session-one"))
        XCTAssertFalse(allowed)
        XCTAssertEqual(presenter.promptCount, 0, "backgrounded/locked requests must auto-deny with no sheet")
    }

    func testLateSecondResolveIsIgnored() async {
        let presenter = makePresenter()
        let pendingRequest = request(sessionID: "s")
        async let decision: AgentAuthorizationDecision = presenter.decide(pendingRequest)
        let pending = await waitUntilPending(presenter)
        XCTAssertTrue(pending)
        presenter.resolve(.deny)
        presenter.resolve(.allowOnce)
        let resolved = await decision
        XCTAssertEqual(resolved, .deny, "first decision wins; a late tap must not double-resolve")
    }

    /// A live scene's forwarded-agent request routes its sheet to THAT
    /// scene; the session display name comes from the scene's connection.
    func testPromptRoutesToTheOriginatingScene() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let snapshots = InMemoryAppSnapshotStore()
        let alpha = try Connection(
            name: "Alpha",
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
        let store = SessionStore(
            transportFactory: factory,
            snapshotStore: snapshots,
            connectionLookup: { _ in alpha }
        )

        let descriptor = store.openSession(for: alpha)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model.state != .active {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .active)

        let bridgeSessionIDs = store.agentBook.sessionIDs()
        XCTAssertEqual(bridgeSessionIDs.count, 1, "one transport = one bridge session identity")
        let bridgeSessionID = try XCTUnwrap(bridgeSessionIDs.first)

        let routingRequest = request(sessionID: bridgeSessionID, fingerprint: "SHA256:route")
        async let decision: AgentAuthorizationDecision = store.agentPresenter.decide(routingRequest)
        let pending = await waitUntilPending(store.agentPresenter)
        XCTAssertTrue(pending)
        XCTAssertEqual(store.agentPresenter.routing?.target, .scene(descriptor.id))
        XCTAssertEqual(store.agentPresenter.routing?.sessionDisplayName, "Alpha")
        XCTAssertTrue(store.agentPresenter.isTargeting(scene: descriptor.id))

        store.agentPresenter.denyPendingIfTargeting(scene: descriptor.id)
        let resolved = await decision
        XCTAssertEqual(resolved, .deny)
        XCTAssertNil(store.agentPresenter.pendingRequest)
    }
}
