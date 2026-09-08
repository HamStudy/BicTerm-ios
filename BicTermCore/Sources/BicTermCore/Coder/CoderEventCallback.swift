import Foundation

/// What produced a ``CoderNetEvent``: the layer whose observation it reports.
public enum CoderNetEventSource: String, Codable, Sendable {
    /// Primary Coder REST API (workspace/agent metadata, usage).
    case rest
    /// Tailnet coordination channel (WebSocket + yamux + DRPC).
    case coord
    /// DERP relay transport.
    case derp
    /// The agent SSH session itself.
    case ssh
}

/// Network-path kind carried by a `networkPathChanged` event (spec §10.1).
public enum CoderNetPathKind: String, Codable, Sendable {
    case direct
    case relayed
}

/// The taxonomy of lifecycle/auth/network diagnostics the Go core emits
/// (spec §8.7 + §15). Wire strings match the task contract exactly; the Go
/// side classifies resume-token rejections internally before ever naming
/// one `authRequired` — see ``CoderEventClassifier`` for the Swift-side belt.
public enum CoderNetEventType: String, Codable, Sendable {
    /// Genuine primary 401 (REST or coordination) WITHOUT the resume-token
    /// validation marker. The only type that may surface as auth loss.
    case authRequired
    /// The coordination channel dropped; the Go core reconnects with its
    /// resume token (spec §8.7). Never a session state change.
    case coordReconnecting
    /// Direct/relay path changed (spec §14.4 row 2: the network engine owns
    /// re-discovery). `path` names the new kind.
    case networkPathChanged
    /// The SSH-level session ended irrecoverably (EOF, agent restart).
    case sshClosed
    /// The coordination resume token was discarded and/or refreshed (§8.7 —
    /// including after a resume-token 401 retry). Internal bookkeeping only.
    case resumeRefreshed
    /// Bounded-retry transient failure (429/5xx/DNS). Logged, never fatal.
    case transientError
}

/// One structured lifecycle event crossing the Go→Swift boundary.
///
/// Transport contract (spec §13, `ConnectionManager.Events()`): the Go
/// bridge delivers these as single-line JSON envelopes on its existing log
/// callback channel, tagged by ``CoderNetEvent/bridgeMarker`` so plain
/// diagnostics and structured events share one channel. `handle` tags
/// session-derived events with the Go session handle so multi-session apps
/// can route them; unattributed events (`handle == nil`) describe the core
/// itself and carry no routing anchor.
public struct CoderNetEvent: Codable, Equatable, Sendable {
    /// The envelope key marking a log line as a structured event.
    public static let bridgeMarker = "codernet_event"

    public let type: CoderNetEventType
    public let source: CoderNetEventSource
    public let httpStatus: Int?
    /// names of the validation fields a Coder error body carried (e.g.
    /// `resume_token`) — the §15 discriminator.
    public let validations: [String]?
    /// The Go session handle this observation belongs to, when attributable.
    public let handle: Int?
    /// The new path kind for `networkPathChanged`; nil otherwise.
    public let path: CoderNetPathKind?

    public init(
        type: CoderNetEventType,
        source: CoderNetEventSource,
        httpStatus: Int? = nil,
        validations: [String]? = nil,
        handle: Int? = nil,
        path: CoderNetPathKind? = nil
    ) {
        self.type = type
        self.source = source
        self.httpStatus = httpStatus
        self.validations = validations
        self.handle = handle
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case type, source, validations, handle, path
        case httpStatus = "http_status"
    }

    private struct Envelope: Codable {
        let event: CoderNetEvent

        private enum CodingKeys: String, CodingKey {
            case event = "codernet_event"
        }
    }

    /// Parse one log-callback line. Tagged well-formed lines yield an event;
    /// anything else (plain diagnostics, unknown types from a newer core) is
    /// NOT an event and stays a diagnostic — unknown types must never be
    /// guessed at (spec §15: misclassification is worse than a dropped log).
    public static func parse(bridgeLine line: String) -> CoderNetEvent? {
        guard line.contains(bridgeMarker) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)).event
    }

    /// The tagged single-line envelope a producer emits (fakes and the Go
    /// bridge share this exact shape).
    public func encodedBridgeLine() -> String {
        struct Out: Encodable {
            let codernet_event: CoderNetEvent
        }
        return String(
            decoding: (try? JSONEncoder().encode(Out(codernet_event: self))) ?? Data(),
            as: UTF8.self
        )
    }
}

/// What the Swift layer does with one ``CoderNetEvent``.
public enum CoderEventDisposition: Equatable, Sendable {
    /// Genuine primary 401: mark the credential generation `AuthRequired`
    /// (spec §14.5 step 3) and stop new dials.
    case authRequired
    /// SSH-level EOF (spec §14.4 row 3): park the session at
    /// reconnect-required; never replay a command.
    case sessionReconnectRequired
    /// Coord recovery, path changes, resume refreshes, transient errors —
    /// internal to the network core; no session or credential state moves.
    case consumeInternally
}

/// The §15 classification discipline, enforced AGAIN at the Swift boundary:
/// any event whose `validations` names `resume_token` is a resume-token
/// rejection (§8.7 — the Go core discards the token and retries without it)
/// and MUST NOT surface as ``authRequired``, whatever type tag it arrived
/// with. Everything else is type-driven.
public enum CoderEventClassifier {
    static let resumeTokenField = "resume_token"

    public static func disposition(of event: CoderNetEvent) -> CoderEventDisposition {
        if event.validations?.contains(resumeTokenField) == true {
            return .consumeInternally
        }
        switch event.type {
        case .authRequired:
            return .authRequired
        case .sshClosed:
            return .sessionReconnectRequired
        case .coordReconnecting, .networkPathChanged, .resumeRefreshed, .transientError:
            return .consumeInternally
        }
    }
}
