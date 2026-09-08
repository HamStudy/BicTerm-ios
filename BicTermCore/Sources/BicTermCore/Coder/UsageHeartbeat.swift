import Foundation

/// Identity of one real SSH session for usage reporting (spec §14.3): the
/// POST target plus the exact body the API consumes. Token bytes cross into
/// a request header only at POST time and are never logged.
public struct CoderUsageScope: Equatable, Sendable {
    public let serverURL: URL
    public let workspaceID: UUID
    public let agentID: UUID
    /// Spec-mandated body value: the SSH client's fixed usage identity.
    public static let appName = "ssh"
    let sessionToken: String

    public init(serverURL: URL, sessionToken: String, workspaceID: UUID, agentID: UUID) {
        self.serverURL = serverURL
        self.sessionToken = sessionToken
        self.workspaceID = workspaceID
        self.agentID = agentID
    }
}

/// The lifecycle seam transports drive: `begin` when a real session attaches,
/// `end` on detach/close or when the credential generation is marked
/// `AuthRequired` (transient errors NEVER stop reporting — they are logged).
public protocol CoderUsageReporting: Sendable {
    func begin(_ scope: CoderUsageScope) async
    func end() async
}

/// Interval abstraction so tests drive the cadence with an injected clock.
public protocol UsageHeartbeatSleeper: Sendable {
    /// Suspends for `interval`; throws `CancellationError` when cancelled.
    func sleep(for interval: Duration) async throws(CancellationError)
}

public struct SystemUsageHeartbeatSleeper: UsageHeartbeatSleeper {
    public init() {}

    public func sleep(for interval: Duration) async throws(CancellationError) {
        do {
            try await Task.sleep(for: interval)
        } catch {
            // Task.sleep(for:) throws only CancellationError.
            throw CancellationError()
        }
    }
}

/// Spec §14.3 usage heartbeat: on `begin`, POST
/// `/api/v2/workspaces/{id}/usage` with `{agent_id, app_name:"ssh"}`
/// immediately, then every 60s until `end()`
/// cancellation. Mirrors the reference CLI's initial-update-then-periodic
/// shape.
///
/// Failure posture (§14.3, §15): every failure is recorded on the
/// observation sink and the loop CONTINUES — a failed optional usage call is
/// explicitly not proof of authentication loss, so heartbeat outcomes never
/// touch credential-generation state. Only `end()` stops the loop.
public actor UsageHeartbeat: CoderUsageReporting {
    public static let interval: Duration = .seconds(60)

    /// Observability for a component without a logger of its own: transports
    /// and coordinators subscribe; failures are data, not throws.
    public enum Event: Equatable, Sendable {
        case posted(statusCode: Int)
        case requestFailed(CoderRequestLoadingError)
        case unexpectedStatus(Int)
    }

    private let requestLoader: any CoderRequestLoading
    private let sleeper: any UsageHeartbeatSleeper
    private let observe: @Sendable (Event) -> Void
    private var loopTask: Task<Void, Never>?

    public init(
        requestLoader: any CoderRequestLoading = SystemCoderRequestLoader(),
        sleeper: any UsageHeartbeatSleeper = SystemUsageHeartbeatSleeper(),
        observe: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.requestLoader = requestLoader
        self.sleeper = sleeper
        self.observe = observe
    }

    /// Attaches a real session: cancels any prior loop, posts immediately,
    /// then repeats every ``interval``.
    public func begin(_ scope: CoderUsageScope) {
        loopTask?.cancel()
        loopTask = Task { [requestLoader, sleeper, observe] in
            await Self.post(scope, loader: requestLoader, observe: observe)
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(for: Self.interval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await Self.post(scope, loader: requestLoader, observe: observe)
            }
        }
    }

    /// Detach/close/generation-mark: stop posting. Terminal for the current
    /// loop; idempotent.
    public func end() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One POST. 2xx (spec expects 204) records `.posted`; loader errors and
    /// non-2xx statuses record failures. Never throws: usage reporting
    /// failure must not perturb the session it reports on.
    private static func post(
        _ scope: CoderUsageScope,
        loader: any CoderRequestLoading,
        observe: @Sendable (Event) -> Void
    ) async {
        struct Body: Encodable {
            let agent_id: String
            let app_name: String
        }
        let url = scope.serverURL.appendingPathComponent(
            "api/v2/workspaces/\(scope.workspaceID.uuidString.lowercased())/usage"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(scope.sessionToken, forHTTPHeaderField: "Coder-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The body has no fallible members; encoding cannot fail.
        request.httpBody = (try? JSONEncoder().encode(Body(
            agent_id: scope.agentID.uuidString.lowercased(),
            app_name: CoderUsageScope.appName
        ))) ?? Data()

        let response: CoderHTTPResponse
        do {
            response = try await loader.load(request)
        } catch let error as CoderRequestLoadingError {
            observe(.requestFailed(error))
            return
        }
        switch response.statusCode {
        case 200..<300:
            observe(.posted(statusCode: response.statusCode))
        default:
            observe(.unexpectedStatus(response.statusCode))
        }
    }
}
