import Foundation

public struct CoderClient: Sendable {
    private let tokenStore: any CoderTokenStoring
    private let requestLoader: any CoderRequestLoading
    private let retrySleeper: any CoderRetrySleeping
    private let pageSize: Int

    public init(
        tokenStore: any CoderTokenStoring = KeychainCoderTokenStore(),
        requestLoader: any CoderRequestLoading = SystemCoderRequestLoader(),
        retrySleeper: any CoderRetrySleeping = SystemCoderRetrySleeper(),
        pageSize: Int = 100
    ) {
        self.tokenStore = tokenStore
        self.requestLoader = requestLoader
        self.retrySleeper = retrySleeper
        self.pageSize = max(1, pageSize)
    }

    public func workspaces(for server: CoderServer) async throws(CoderClientError) -> [CoderWorkspace] {
        let token: String?
        do {
            token = try await tokenStore.token(for: server.tokenKeychainTag)
        } catch {
            throw .tokenStorageFailure
        }
        guard let token, !token.isEmpty else { throw .unauthorized }

        var workspaces: [CoderWorkspace] = []
        var offset = 0
        var rateLimitRetryAvailable = true

        while true {
            let request = try workspaceRequest(for: server, token: token, offset: offset)
            let result = try await perform(request, retryRateLimit: rateLimitRetryAvailable)
            if result.didRetryRateLimit { rateLimitRetryAvailable = false }
            let envelope = try decodeEnvelope(result.response.body)
            workspaces.append(contentsOf: envelope.workspaces)

            if workspaces.count >= envelope.count { return workspaces }
            guard !envelope.workspaces.isEmpty else { throw .malformedResponse }
            offset += envelope.workspaces.count
        }
    }

    /// Validates the candidate against one workspace-list request and commits
    /// it only after that request and payload succeed. Existing durable tokens
    /// therefore survive every validation failure.
    public func validateAndSaveToken(
        _ candidate: String,
        for server: CoderServer
    ) async throws(CoderClientError) {
        let request = try workspaceRequest(for: server, token: candidate, offset: 0)
        let result = try await perform(request, retryRateLimit: true)
        _ = try decodeEnvelope(result.response.body)

        do {
            try await tokenStore.save(candidate, for: server.tokenKeychainTag)
        } catch {
            throw .tokenStorageFailure
        }
    }

    private func workspaceRequest(
        for server: CoderServer,
        token: String,
        offset: Int
    ) throws(CoderClientError) -> URLRequest {
        let endpoint = server.baseURL.appendingPathComponent("api/v2/workspaces")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw .invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: "owner:me"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components.url else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Coder-Session-Token")
        return request
    }

    private func perform(
        _ request: URLRequest,
        retryRateLimit: Bool
    ) async throws(CoderClientError) -> (response: CoderHTTPResponse, didRetryRateLimit: Bool) {
        let first = try await load(request)
        guard first.statusCode == 429 else {
            try validateStatus(first)
            return (first, false)
        }

        let firstDelay = retryAfter(from: first)
        guard retryRateLimit else { throw .rateLimited(retryAfter: firstDelay) }
        if let firstDelay {
            do {
                try await retrySleeper.sleep(for: firstDelay)
            } catch {
                throw .requestCancelled
            }
        }

        let second = try await load(request)
        if second.statusCode == 429 {
            throw .rateLimited(retryAfter: retryAfter(from: second))
        }
        try validateStatus(second)
        return (second, true)
    }

    private func load(_ request: URLRequest) async throws(CoderClientError) -> CoderHTTPResponse {
        do {
            return try await requestLoader.load(request)
        } catch let error {
            switch error {
            case .invalidURL: throw .invalidURL
            case .tlsFailure: throw .tlsFailure
            case .networkFailure: throw .networkFailure
            case .invalidResponse: throw .malformedResponse
            case .cancelled: throw .requestCancelled
            }
        }
    }

    private func validateStatus(_ response: CoderHTTPResponse) throws(CoderClientError) {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw .unauthorized
        case 403:
            throw .forbidden
        case 429:
            throw .rateLimited(retryAfter: retryAfter(from: response))
        case 500..<600:
            throw .serverError(statusCode: response.statusCode)
        default:
            throw .unexpectedStatusCode(response.statusCode)
        }
    }

    private func retryAfter(from response: CoderHTTPResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(rawValue),
              seconds >= 0 else {
            return nil
        }
        return TimeInterval(seconds)
    }

    private func decodeEnvelope(_ body: Data) throws(CoderClientError) -> WorkspaceEnvelope {
        do {
            let envelope = try JSONDecoder().decode(WorkspaceEnvelope.self, from: body)
            guard envelope.count >= 0 else { throw CoderClientError.malformedResponse }
            return envelope
        } catch let error as CoderClientError {
            throw error
        } catch {
            throw .malformedResponse
        }
    }
}

private struct WorkspaceEnvelope: Decodable, Sendable {
    let workspaces: [CoderWorkspace]
    let count: Int
}
