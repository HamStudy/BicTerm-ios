import Foundation
import XCTest
@testable import BicTermCore

/// T10: usage heartbeat (spec §14.3). Deterministic cadence via an injected
/// sleeper: the test releases intervals explicitly, so a 60s-period loop is
/// proven without wall-clock waiting. Failures must be recorded, never
/// thrown, and never stop the loop.
final class UsageHeartbeatTests: XCTestCase {
    private let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let agentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private func makeScope() -> CoderUsageScope {
        CoderUsageScope(
            serverURL: URL(string: "https://coder.fixture.invalid")!,
            sessionToken: "fixture-token",
            workspaceID: workspaceID,
            agentID: agentID
        )
    }

    private func makeHeartbeat(
        loader: HeartbeatLoader,
        sleeper: ManualSleeper,
        events: HeartbeatEventLog
    ) -> UsageHeartbeat {
        UsageHeartbeat(requestLoader: loader, sleeper: sleeper) { event in
            Task { await events.append(event) }
        }
    }

    // MARK: - Cadence and wire shape

    /// Releases exactly one interval: first proves the loop is parked (a
    /// release into an un-parked loop would otherwise vanish and flake).
    private func releaseOneInterval(_ sleeper: ManualSleeper) async {
        let parked = await waitForSuiteCondition { sleeper.pendingCount() == 1 }
        XCTAssertTrue(parked, "the heartbeat loop must be parked on its interval")
        sleeper.releaseOne()
    }

    func testBeginPostsImmediatelyThenOncePerReleasedInterval() async throws {
        let loader = HeartbeatLoader(responses: [.success(CoderHTTPResponse(statusCode: 204, body: Data()))])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())

        let firstLanded = await waitForSuiteCondition { await loader.requestCount() == 1 }
        XCTAssertTrue(firstLanded, "begin must post immediately, like the reference implementation")

        await releaseOneInterval(sleeper)
        let secondLanded = await waitForSuiteCondition { await loader.requestCount() == 2 }
        XCTAssertTrue(secondLanded)
        await releaseOneInterval(sleeper)
        let thirdLanded = await waitForSuiteCondition { await loader.requestCount() == 3 }
        XCTAssertTrue(thirdLanded, "each released interval posts exactly one update")
        await heartbeat.end()
    }

    func testPostedRequestMatchesSpecShape() async throws {
        let loader = HeartbeatLoader(responses: [.success(CoderHTTPResponse(statusCode: 204, body: Data()))])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())
        let landed = await waitForSuiteCondition { await loader.requestCount() == 1 }
        XCTAssertTrue(landed)

        let recorded = await loader.firstRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path,
            "/api/v2/workspaces/\(workspaceID.uuidString.lowercased())/usage"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Coder-Session-Token"), "fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decoded["agent_id"], agentID.uuidString.lowercased())
        XCTAssertEqual(decoded["app_name"], "ssh")
        await heartbeat.end()
    }

    // MARK: - Failures are logged and non-fatal

    func testRequestFailureIsRecordedAndLoopContinues() async {
        let loader = HeartbeatLoader(responses: [
            .success(CoderHTTPResponse(statusCode: 204, body: Data())),
            .failure(.networkFailure),
            .success(CoderHTTPResponse(statusCode: 204, body: Data())),
        ])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())
        _ = await waitForSuiteCondition { await loader.requestCount() == 1 }
        await releaseOneInterval(sleeper)
        let failureLogged = await waitForSuiteCondition { await events.contains(.requestFailed(.networkFailure)) }
        XCTAssertTrue(failureLogged, "load failures must be recorded on the observation sink")
        await releaseOneInterval(sleeper)
        let recovered = await waitForSuiteCondition { await events.count(of: .posted(statusCode: 204)) == 2 }
        XCTAssertTrue(recovered, "a failed optional usage POST must not stop the loop")
        await heartbeat.end()
    }

    func testUnexpectedStatusIsRecordedAndNeverFatal() async {
        let loader = HeartbeatLoader(responses: [
            .success(CoderHTTPResponse(statusCode: 500, body: Data())),
            .success(CoderHTTPResponse(statusCode: 204, body: Data())),
        ])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())
        let errorLogged = await waitForSuiteCondition { await events.contains(.unexpectedStatus(500)) }
        XCTAssertTrue(errorLogged)
        await releaseOneInterval(sleeper)
        let recovered = await waitForSuiteCondition { await events.contains(.posted(statusCode: 204)) }
        XCTAssertTrue(recovered)
        await heartbeat.end()
    }

    func testUsage401IsNotAnAuthLossSignal() async {
        // Spec §14.3: a failed usage call is not proof that authorization
        // disappeared — it is recorded like any failure, and the loop runs on.
        let loader = HeartbeatLoader(responses: [
            .success(CoderHTTPResponse(statusCode: 401, body: Data())),
            .success(CoderHTTPResponse(statusCode: 204, body: Data())),
        ])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())
        _ = await waitForSuiteCondition { await events.contains(.unexpectedStatus(401)) }
        await releaseOneInterval(sleeper)
        let keptGoing = await waitForSuiteCondition { await events.contains(.posted(statusCode: 204)) }
        XCTAssertTrue(keptGoing, "a 401 on the usage endpoint must not stop or escalate anything")
        await heartbeat.end()
    }

    // MARK: - Stop semantics

    func testEndStopsPosting() async {
        let loader = HeartbeatLoader(responses: [.success(CoderHTTPResponse(statusCode: 204, body: Data()))])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.begin(makeScope())
        _ = await waitForSuiteCondition { await loader.requestCount() == 1 }
        await heartbeat.end()

        // Give a (wrongly) surviving loop a full released interval to act.
        sleeper.releaseOne()
        try? await Task.sleep(for: .milliseconds(100))
        let afterEnd = await loader.requestCount()
        XCTAssertEqual(afterEnd, 1, "no posts after end()")
    }

    func testEndWithoutBeginIsHarmlessAndBeginTwiceNeverDoublesCadence() async {
        let loader = HeartbeatLoader(responses: [.success(CoderHTTPResponse(statusCode: 204, body: Data()))])
        let sleeper = ManualSleeper()
        let events = HeartbeatEventLog()
        let heartbeat = makeHeartbeat(loader: loader, sleeper: sleeper, events: events)

        await heartbeat.end()
        await heartbeat.begin(makeScope())
        let firstReady = await waitForSuiteCondition { await loader.requestCount() == 1 && sleeper.pendingCount() == 1 }
        XCTAssertTrue(firstReady)

        // The second begin cancels the first loop synchronously (its pending
        // nap is drained before the replacement task exists), then posts.
        await heartbeat.begin(makeScope())
        let secondReady = await waitForSuiteCondition { await loader.requestCount() == 2 && sleeper.pendingCount() == 1 }
        XCTAssertTrue(secondReady, "the replacement loop posts once and parks exactly one interval")

        await releaseOneInterval(sleeper)
        let thirdLanded = await waitForSuiteCondition { await loader.requestCount() == 3 }
        XCTAssertTrue(thirdLanded)
        try? await Task.sleep(for: .milliseconds(100))
        let finalCount = await loader.requestCount()
        XCTAssertEqual(
            finalCount, 3,
            "a second begin replaces the loop instead of doubling the cadence"
        )
        await heartbeat.end()
    }
}

/// Loader that replays scripted responses and records every request.
private actor HeartbeatLoader: CoderRequestLoading {
    private var responses: [Result<CoderHTTPResponse, CoderRequestLoadingError>]
    private var requests: [URLRequest] = []

    init(responses: [Result<CoderHTTPResponse, CoderRequestLoadingError>]) {
        self.responses = responses
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return CoderHTTPResponse(statusCode: 204, body: Data())
        }
        return try responses.removeFirst().get()
    }

    func requestCount() -> Int { requests.count }
    func firstRequest() -> URLRequest? { requests.first }
}

/// Manually driven `UsageHeartbeatSleeper`: each `sleep` registers
/// synchronously and parks until ``releaseOne()`` (or task cancellation)
/// resumes it, so the test drives the 60s cadence without wall-clock waits.
/// Lock-confined like the codebase's other cross-executor test doubles; no
/// lock ever straddles an await.
private final class ManualSleeper: UsageHeartbeatSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, any Error>] = []
    /// A cancel that arrived while nobody was parked: the next parker
    /// consumes it instead of leaking.
    private var cancellationOutstanding = false

    func sleep(for interval: Duration) async throws(CancellationError) {
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    lock.withLock {
                        if cancellationOutstanding {
                            cancellationOutstanding = false
                            continuation.resume(throwing: CancellationError())
                        } else {
                            pending.append(continuation)
                        }
                    }
                }
            } onCancel: {
                cancelPending()
            }
        } catch {
            // The operation's only throw site is CancellationError.
            throw CancellationError()
        }
    }

    func pendingCount() -> Int { lock.withLock { pending.count } }

    func releaseOne() {
        let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
            pending.isEmpty ? nil : pending.removeFirst()
        }
        waiter?.resume()
    }

    private func cancelPending() {
        let waiters: [CheckedContinuation<Void, any Error>] = lock.withLock {
            let parked = pending
            pending = []
            cancellationOutstanding = parked.isEmpty
            return parked
        }
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}

private actor HeartbeatEventLog {
    private var events: [UsageHeartbeat.Event] = []
    func append(_ event: UsageHeartbeat.Event) { events.append(event) }
    func contains(_ event: UsageHeartbeat.Event) -> Bool { events.contains(event) }
    func count(of event: UsageHeartbeat.Event) -> Int { events.filter { $0 == event }.count }
}
