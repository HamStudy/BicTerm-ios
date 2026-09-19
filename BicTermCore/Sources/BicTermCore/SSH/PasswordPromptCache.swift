/// Coalesces password prompts for one bring-up: the first prompt for a
/// destination reaches the underlying prompter, concurrent prompts for the
/// same destination await that one in-flight prompt, and later prompts
/// return the remembered answer — including a decline, so a redial loop can
/// never spam the prompt. Answers stay memory-only and live exactly as long
/// as this cache (one bring-up); persistence stays the prompt's own concern.
public actor PasswordPromptCache {
    private enum Answer {
        case declined
        case password(String)
    }

    private var answered: [String: Answer] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    public init() {}

    nonisolated public func wrapping(
        _ underlying: (any SSHPasswordPrompting)?
    ) -> (any SSHPasswordPrompting)? {
        guard let underlying else { return nil }
        return CachedPrompt(cache: self, underlying: underlying)
    }

    func password(
        forKey key: String,
        request: SSHPasswordRequest,
        underlying: any SSHPasswordPrompting
    ) async -> String? {
        if let answer = answered[key] {
            switch answer {
            case .declined:
                return nil
            case .password(let password):
                return password
            }
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { await underlying.promptForPassword(request) }
        inFlight[key] = task
        let password = await task.value
        answered[key] = password.map(Answer.password) ?? .declined
        inFlight[key] = nil
        return password
    }
}

private struct CachedPrompt: SSHPasswordPrompting {
    let cache: PasswordPromptCache
    let underlying: any SSHPasswordPrompting

    func promptForPassword(_ request: SSHPasswordRequest) async -> String? {
        await cache.password(forKey: Self.key(for: request), request: request, underlying: underlying)
    }

    /// Jump-hop prompts carry no remember tag; they key on the destination
    /// identity itself so hops to distinct servers never share an answer.
    private static func key(for request: SSHPasswordRequest) -> String {
        request.saveTag ?? "\(request.username)@\(request.host):\(request.port)"
    }
}
