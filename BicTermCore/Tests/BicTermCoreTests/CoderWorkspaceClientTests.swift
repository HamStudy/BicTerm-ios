import Foundation
import Security
import XCTest
@testable import BicTermCore

final class CoderWorkspaceClientTests: XCTestCase {
    func testExpiredTokenReturnsReauthenticationRequired() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(statusCode: 401, body: #"{"message":"invalid api key"}"#)),
        ])
        let client = makeClient(loader: loader)
        let coderServer = try server()

        do {
            _ = try await client.workspaces(for: coderServer)
            XCTFail("An expired token must require reauthentication")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertTrue(error.requiresReauthentication)
        }
    }

    func testStoppedWorkspaceIsNotConnectable() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: ["stopped"]))),
        ])
        let client = makeClient(loader: loader)

        let workspaces = try await client.workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.state, .stopped)
        XCTAssertFalse(workspace.isConnectable)
    }

    func testWorkspaceDiscoveryAggregatesPaginationUsingCoderRequestContract() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: ["running", "starting"], count: 3))),
            .success(response(body: workspaceEnvelope(states: ["stopped"], count: 3, idOffset: 2))),
        ])
        let tokenStore = InMemoryCoderTokenStore(tokens: [tokenTag: TestModels.tokenFixture])
        let client = CoderClient(
            tokenStore: tokenStore,
            requestLoader: loader,
            retrySleeper: RecordingCoderRetrySleeper(),
            pageSize: 2
        )

        let workspaces = try await client.workspaces(for: server())
        let requests = await loader.recordedRequests()

        XCTAssertEqual(workspaces.map(\.name), ["workspace-1", "workspace-2", "workspace-3"])
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v2/workspaces")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Coder-Session-Token"), TestModels.tokenFixture)

            let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "owner:me")
            XCTAssertEqual(query["limit"], "2")
            XCTAssertEqual(query["offset"], String(index * 2))
        }
    }

    func testAllUpstreamWorkspaceStatesRemainDistinct() async throws {
        let rawStates = [
            "pending", "starting", "running", "stopping", "stopped", "failed",
            "canceling", "canceled", "deleting", "deleted",
        ]
        let expected: [CoderWorkspaceState] = [
            .pending, .starting, .running, .stopping, .stopped, .failed,
            .canceling, .canceled, .deleting, .deleted,
        ]
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: rawStates))),
        ])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())

        XCTAssertEqual(workspaces.map(\.state), expected)
        XCTAssertEqual(workspaces.filter(\.isConnectable).map(\.state), [.running])
    }

    func testUnknownWorkspaceStateIsPreservedAndNotConnectable() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: ["dormant"]))),
        ])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.state, .unknown("dormant"))
        XCTAssertFalse(workspace.isConnectable)
    }

    func testMissingLatestBuildUsesForwardCompatibleUnknownState() async throws {
        let body = #"{"workspaces":[{"id":"11111111-1111-4111-8111-111111111111","name":"workspace-1","owner_name":"fixture-user","unused":null}],"count":1}"#
        let loader = ScriptedCoderRequestLoader([.success(response(body: body))])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.state, .unknown(""))
        XCTAssertFalse(workspace.isConnectable)
    }

    /// Spec §5.1/§5.2: agent identity for the tunnel dial comes from the
    /// latest build's resources, not from a template preview.
    func testWorkspaceAgentsDecodeFromLatestBuildResources() async throws {
        let body = """
        {"workspaces":[{
          "id":"11111111-1111-4111-8111-111111111111",
          "name":"dev",
          "owner_name":"alice",
          "latest_build":{
            "status":"running",
            "resources":[{
              "agents":[{
                "id":"44444444-4444-4444-8444-444444444444",
                "name":"main",
                "status":"connected",
                "lifecycle_state":"ready"
              }]
            }]
          }
        }],"count":1}
        """
        let loader = ScriptedCoderRequestLoader([.success(response(body: body))])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.state, .running)
        let agent = try XCTUnwrap(workspace.agents.first)
        XCTAssertEqual(workspace.agents.count, 1)
        XCTAssertEqual(agent.id, UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        XCTAssertEqual(agent.name, "main")
        XCTAssertTrue(agent.isConnected)
    }

    /// A workspace response that predates per-resource agents (or a build
    /// that has none yet) decodes with an empty agent list, never crashes.
    func testWorkspaceWithoutResourcesDecodesWithNoAgents() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: ["running"]))),
        ])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.agents, [])
    }

    func testNonConnectedAgentIsNotEligible() async throws {
        let body = """
        {"workspaces":[{
          "id":"11111111-1111-4111-8111-111111111111",
          "name":"dev",
          "owner_name":"alice",
          "latest_build":{
            "status":"starting",
            "resources":[{
              "agents":[{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connecting"}]
            }]
          }
        }],"count":1}
        """
        let loader = ScriptedCoderRequestLoader([.success(response(body: body))])

        let workspaces = try await makeClient(loader: loader).workspaces(for: server())
        let workspace = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(workspace.agents.count, 1)
        XCTAssertFalse(workspace.agents[0].isConnected)
    }

    func testRateLimitRetriesOnceAfterRetryAfterDelay() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(statusCode: 429, headers: ["Retry-After": "1"])),
            .success(response(body: workspaceEnvelope(states: ["running"]))),
        ])
        let sleeper = RecordingCoderRetrySleeper()
        let client = makeClient(loader: loader, sleeper: sleeper)

        let workspaces = try await client.workspaces(for: server())
        let delays = await sleeper.recordedDelays()
        let requestCount = await loader.requestCount()

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(delays, [1])
        XCTAssertEqual(requestCount, 2)
    }

    func testFutureHTTPDateRetryAfterUsesInjectedCurrentDate() async throws {
        let currentDate = Date(timeIntervalSince1970: 784_111_747)
        let loader = ScriptedCoderRequestLoader([
            .success(response(
                statusCode: 429,
                headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]
            )),
            .success(response(body: workspaceEnvelope(states: []))),
        ])
        let sleeper = RecordingCoderRetrySleeper()

        _ = try await makeClient(
            loader: loader,
            sleeper: sleeper,
            now: { currentDate }
        ).workspaces(for: server())
        let delays = await sleeper.recordedDelays()
        let requestCount = await loader.requestCount()

        XCTAssertEqual(delays, [30])
        XCTAssertEqual(requestCount, 2)
    }

    func testPastHTTPDateRetryAfterRetriesImmediatelyWithoutNegativeSleep() async throws {
        let currentDate = Date(timeIntervalSince1970: 784_111_787)
        let loader = ScriptedCoderRequestLoader([
            .success(response(
                statusCode: 429,
                headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]
            )),
            .success(response(body: workspaceEnvelope(states: []))),
        ])
        let sleeper = RecordingCoderRetrySleeper()

        _ = try await makeClient(
            loader: loader,
            sleeper: sleeper,
            now: { currentDate }
        ).workspaces(for: server())
        let delays = await sleeper.recordedDelays()
        let requestCount = await loader.requestCount()

        XCTAssertEqual(delays, [0])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(delays.first), 0)
        XCTAssertEqual(requestCount, 2)
    }

    func testSecondRateLimitReturnsTypedErrorWithoutAnotherRetry() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(statusCode: 429, headers: ["Retry-After": "3"])),
            .success(response(statusCode: 429, headers: ["Retry-After": "7"])),
        ])
        let sleeper = RecordingCoderRetrySleeper()
        let client = makeClient(loader: loader, sleeper: sleeper)

        do {
            _ = try await client.workspaces(for: server())
            XCTFail("A second rate limit must end the bounded retry")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 7))
        }
        let delays = await sleeper.recordedDelays()
        let requestCount = await loader.requestCount()
        XCTAssertEqual(delays, [3])
        XCTAssertEqual(requestCount, 2)
    }

    func testMalformedRetryAfterRetriesOnceWithoutSleeping() async throws {
        let loader = ScriptedCoderRequestLoader([
            .success(response(statusCode: 429, headers: ["Retry-After": "not-a-delay"])),
            .success(response(body: workspaceEnvelope(states: []))),
        ])
        let sleeper = RecordingCoderRetrySleeper()

        let workspaces = try await makeClient(loader: loader, sleeper: sleeper).workspaces(for: server())
        let delays = await sleeper.recordedDelays()
        let requestCount = await loader.requestCount()

        XCTAssertEqual(workspaces, [])
        XCTAssertEqual(delays, [])
        XCTAssertEqual(requestCount, 2)
    }

    func testForbiddenReturnsTypedError() async throws {
        try await assertClientError(statusCode: 403, equals: .forbidden)
    }

    func testServerFailureReturnsTypedError() async throws {
        try await assertClientError(statusCode: 503, equals: .serverError(statusCode: 503))
    }

    func testInvalidURLReturnsTypedError() async throws {
        let loader = ScriptedCoderRequestLoader([.failure(.invalidURL)])

        do {
            _ = try await makeClient(loader: loader).workspaces(for: server())
            XCTFail("A bad request URL must be mapped to a typed error")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .invalidURL)
        }
    }

    func testTLSFailureReturnsTypedError() async throws {
        let loader = ScriptedCoderRequestLoader([.failure(.tlsFailure)])

        do {
            _ = try await makeClient(loader: loader).workspaces(for: server())
            XCTFail("A system-trust failure must be mapped to a typed error")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .tlsFailure)
        }
    }

    func testMalformedWorkspacePayloadReturnsTypedError() async throws {
        let malformed = #"{"workspaces":[{"id":"not-a-uuid","name":"workspace","owner_name":"owner","latest_build":{"status":"running"}}],"count":1}"#
        let loader = ScriptedCoderRequestLoader([.success(response(body: malformed))])

        do {
            _ = try await makeClient(loader: loader).workspaces(for: server())
            XCTFail("Malformed workspace JSON must not escape as a decoding error")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testMissingStoredTokenReturnsReauthenticationRequiredWithoutARequest() async throws {
        let loader = ScriptedCoderRequestLoader([])
        let client = CoderClient(
            tokenStore: InMemoryCoderTokenStore(),
            requestLoader: loader,
            retrySleeper: RecordingCoderRetrySleeper()
        )

        do {
            _ = try await client.workspaces(for: server())
            XCTFail("A missing token must require reauthentication")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .unauthorized)
        }
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testSuccessfulTokenValidationSavesCandidateUnderServerTag() async throws {
        let candidate = "candidate-coder-token-value-123456"
        let loader = ScriptedCoderRequestLoader([
            .success(response(body: workspaceEnvelope(states: ["running", "stopped"], count: 3))),
        ])
        let tokenStore = InMemoryCoderTokenStore()
        let client = CoderClient(
            tokenStore: tokenStore,
            requestLoader: loader,
            retrySleeper: RecordingCoderRetrySleeper()
        )

        try await client.validateAndSaveToken(candidate, for: server())

        let savedToken = try await tokenStore.token(for: tokenTag)
        let requests = await loader.recordedRequests()
        let requestCount = await loader.requestCount()
        XCTAssertEqual(savedToken, candidate)
        let validationRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(validationRequest.value(forHTTPHeaderField: "Coder-Session-Token"), candidate)
        XCTAssertEqual(requestCount, 1)
    }

    func testInvalidTokenDoesNotOverwriteExistingValidToken() async throws {
        let existing = "existing-valid-coder-token-123456"
        let candidate = "invalid-candidate-coder-token-654321"
        let loader = ScriptedCoderRequestLoader([
            .success(response(statusCode: 401, body: #"{"message":"invalid api key"}"#)),
        ])
        let tokenStore = InMemoryCoderTokenStore(tokens: [tokenTag: existing])
        let client = CoderClient(
            tokenStore: tokenStore,
            requestLoader: loader,
            retrySleeper: RecordingCoderRetrySleeper()
        )

        do {
            try await client.validateAndSaveToken(candidate, for: server())
            XCTFail("An invalid candidate must not be saved")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, .unauthorized)
        }

        let savedToken = try await tokenStore.token(for: tokenTag)
        XCTAssertEqual(savedToken, existing)
    }

    func testTokenIsNeverDisclosedByErrorDescriptionsOrDebugOutput() async throws {
        let token = TestModels.tokenFixture
        let responseBody = "server-body-contains-\(token)"
        let loader = ScriptedCoderRequestLoader([
            .success(response(
                statusCode: 500,
                headers: ["X-Debug-Secret": token],
                body: responseBody
            )),
        ])

        do {
            _ = try await makeClient(loader: loader, token: token).workspaces(for: server())
            XCTFail("The fixture response must fail")
        } catch let error as CoderClientError {
            let exposedText = [
                String(describing: error),
                String(reflecting: error),
                error.localizedDescription,
                error.debugDescription,
            ].joined(separator: "\n")
            XCTAssertFalse(exposedText.contains(token))
            XCTAssertFalse(exposedText.contains(responseBody))
            XCTAssertFalse(exposedText.contains("X-Debug-Secret"))
            XCTAssertFalse(exposedText.contains("Coder-Session-Token"))
            XCTAssertFalse(exposedText.contains("URLRequest"))
        }
    }

    func testCoderProductionSourcesDoNotLogTokenBearingRequestData() throws {
        let patterns = try forbiddenDiagnosticPatterns()
        let positiveControls = [
            "print(request)",
            "dump(token)",
            "Logger(label: \"coder\")",
            "os_log(\"request failed\")",
            "logger.error(\"token: \\(token)\")",
        ]
        for sample in positiveControls {
            XCTAssertTrue(
                patterns.contains { $0.expression.firstMatch(in: sample, range: sample.fullNSRange) != nil },
                "Coder source-audit detector missed a required diagnostic category"
            )
        }
        let safeDiagnostic = #""CoderHTTPResponse(headerCount: \(headers.count))""#
        XCTAssertFalse(
            patterns.contains {
                $0.expression.firstMatch(in: safeDiagnostic, range: safeDiagnostic.fullNSRange) != nil
            },
            "Coder source-audit detector must allow non-secret metadata"
        )

        var violations: [String] = []
        for file in try coderProductionSourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns where pattern.expression.firstMatch(
                in: source,
                range: source.fullNSRange
            ) != nil {
                violations.append("\(file.lastPathComponent): \(pattern.label)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production Coder sources must not log requests, headers, or tokens: \(violations.joined(separator: ", "))"
        )
    }

    func testKeychainTokenStoreUsesCoderServerTokenKeychainTag() async throws {
        let service = "com.bicterm.tests.coder-token.\(UUID().uuidString)"
        let cleanupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        defer { SecItemDelete(cleanupQuery as CFDictionary) }
        try requireDataProtectionKeychain(service: service)
        let store = KeychainCoderTokenStore(keychainService: service)
        let firstServer = try server(tokenKeychainTag: "coder-server-one")
        let secondServer = try server(tokenKeychainTag: "coder-server-two")

        try await store.save("first-token-value", for: firstServer.tokenKeychainTag)
        try await store.save("second-token-value", for: secondServer.tokenKeychainTag)

        let firstToken = try await store.token(for: firstServer.tokenKeychainTag)
        let secondToken = try await store.token(for: secondServer.tokenKeychainTag)
        XCTAssertEqual(firstToken, "first-token-value")
        XCTAssertEqual(secondToken, "second-token-value")
        try await store.deleteToken(for: firstServer.tokenKeychainTag)
        let deletedToken = try await store.token(for: firstServer.tokenKeychainTag)
        let retainedToken = try await store.token(for: secondServer.tokenKeychainTag)
        XCTAssertNil(deletedToken)
        XCTAssertEqual(retainedToken, "second-token-value")
    }

    private let tokenTag = "keychain://coder/workspace-tests"

    private func server(tokenKeychainTag: String? = nil) throws -> CoderServer {
        try CoderServer(
            name: "Coder Test",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tokenKeychainTag ?? tokenTag
        )
    }

    private func makeClient(
        loader: ScriptedCoderRequestLoader,
        sleeper: RecordingCoderRetrySleeper = RecordingCoderRetrySleeper(),
        token: String = TestModels.tokenFixture,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CoderClient {
        CoderClient(
            tokenStore: InMemoryCoderTokenStore(tokens: [tokenTag: token]),
            requestLoader: loader,
            retrySleeper: sleeper,
            pageSize: 20,
            now: now
        )
    }

    private func coderProductionSourceFiles() throws -> [URL] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coderSources = packageRoot.appendingPathComponent("Sources/BicTermCore/Coder")
        guard let enumerator = FileManager.default.enumerator(
            at: coderSources,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            XCTFail("Could not enumerate production Coder sources")
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private func forbiddenDiagnosticPatterns() throws -> [ForbiddenDiagnosticPattern] {
        let definitions = [
            ("print/debugPrint/dump call", #"\b(?:print|debugPrint|dump)\s*\("#),
            ("Logger use", #"\bLogger\s*(?:\(|\.)"#),
            ("os_log call", #"\bos_log(?:_[A-Za-z]+)?\s*\("#),
            ("logger method call", #"\b(?:logger|log)\s*\.\s*(?:trace|debug|info|notice|warning|error|critical|fault)\s*\("#),
            (
                "token-bearing diagnostic interpolation",
                #"(?i)\\\(\s*(?:(?:token|candidate|keychainTag)(?:\b|\.)|(?:request|headers?)(?!\s*\.count\b)(?:\b|\.))"#
            ),
        ]
        return try definitions.map { label, pattern in
            ForbiddenDiagnosticPattern(
                label: label,
                expression: try NSRegularExpression(pattern: pattern)
            )
        }
    }

    private func assertClientError(
        statusCode: Int,
        equals expected: CoderClientError
    ) async throws {
        let loader = ScriptedCoderRequestLoader([.success(response(statusCode: statusCode))])

        do {
            _ = try await makeClient(loader: loader).workspaces(for: server())
            XCTFail("HTTP \(statusCode) must produce a typed Coder error")
        } catch let error as CoderClientError {
            XCTAssertEqual(error, expected)
        }
    }

    private func response(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String = #"{"workspaces":[],"count":0}"#
    ) -> CoderHTTPResponse {
        CoderHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data(body.utf8)
        )
    }

    private func workspaceEnvelope(states: [String], count: Int? = nil, idOffset: Int = 0) -> String {
        let workspaces = states.enumerated().map { index, state -> [String: Any] in
            let ordinal = idOffset + index + 1
            return [
                "id": String(format: "%08d-0000-4000-8000-%012d", ordinal, ordinal),
                "name": "workspace-\(ordinal)",
                "owner_name": "fixture-user",
                "latest_build": ["status": state, "unused": NSNull()],
                "unused": ["nested": true],
            ]
        }
        let object: [String: Any] = [
            "workspaces": workspaces,
            "count": count ?? states.count,
            "unused": NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func requireDataProtectionKeychain(service: String) throws {
        let account = "preflight"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data("preflight".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("SPM simulator test bundle has no Data Protection Keychain entitlement")
        }
        guard status == errSecSuccess else {
            throw CoderTokenStoreError.keychain(status)
        }
        SecItemDelete(query as CFDictionary)
    }
}

private struct ForbiddenDiagnosticPattern {
    let label: String
    let expression: NSRegularExpression
}

private extension String {
    var fullNSRange: NSRange {
        NSRange(startIndex..<endIndex, in: self)
    }
}

private actor ScriptedCoderRequestLoader: CoderRequestLoading {
    private var results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]
    private var requests: [URLRequest] = []

    init(_ results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]) {
        self.results = results
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw .networkFailure }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor RecordingCoderRetrySleeper: CoderRetrySleeping {
    private var delays: [TimeInterval] = []

    func sleep(for delay: TimeInterval) async throws(CoderRetrySleepingError) {
        delays.append(delay)
    }

    func recordedDelays() -> [TimeInterval] {
        delays
    }
}

private actor InMemoryCoderTokenStore: CoderTokenStoring {
    private var tokens: [String: String]

    init(tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        tokens[keychainTag]
    }

    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = token
    }

    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = nil
    }
}
