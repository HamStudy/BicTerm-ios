import Foundation

/// How a ``TerminalTransport`` comes back from `suspend()`. This is the
/// capability that keeps the abstraction from being SSH-shaped:
///
/// - `.rehandshake` (SSH): suspend tears the connection down; "resume"
///   means building a FRESH transport from the factory (full TCP +
///   handshake + auth). The suspended instance's `resume()` throws
///   ``TransportError/resumeUnsupported``.
/// - `.nativeRoaming` (future ET/mosh): the session survives server-side;
///   `resume()` reattaches the SAME instance WITHOUT re-authenticating.
public enum ResumeStrategy: Equatable, Sendable {
    case rehandshake
    case nativeRoaming
}

/// The complete contract every remote-session protocol (SSH, future
/// ET/mosh, …) implements. The session layer (`SessionRegistry`) and the
/// terminal layer consume ONLY this protocol — no wire types (NIO
/// channels, SSH error enums) appear anywhere in this surface.
///
/// Lifecycle: one instance == one connection attempt. `connect` performs
/// whatever handshake/auth the protocol needs; `close()` is terminal,
/// idempotent, finishes `output`, and makes every subsequent `send` throw
/// ``TransportError/channelDenied``.
///
/// I/O model and backpressure:
/// - INPUT path: `send(_:)` (or `pipe(input:)` for an
///   `AsyncStream<Data>` producer). `send` is `async` precisely so a
///   conformer can SUSPEND the caller under flow control (SSH blocks while
///   the channel window is exhausted) instead of queueing unbounded
///   writes. `pipe(input:)` forwards that backpressure to the stream's
///   producer, which is why input is modeled as a suspending write path
///   rather than a second continuation: the terminal produces bytes and
///   must be slowed, never the transport.
/// - OUTPUT path: `output`, a fresh-per-connect `AsyncStream<Data>`,
///   bounded `.bufferingNewest(32)` — a slow consumer loses scrollback,
///   never blocks the network read path.
///
/// Suspend/resume map onto the session state machine via
/// ``resumeStrategy``; see ``ResumeStrategy``. The default implementations
/// below give every conformer the SSH-shaped behavior for free.
///
/// Class-bound: a transport is a stateful connection handle whose identity
/// the session layer relies on (output-bridging guards on it). Every
/// conformer is expected to be an actor.
public protocol TerminalTransport: Sendable, AnyObject {
    /// Bytes from the remote side. Fresh per `connect`; finishes on drop
    /// or `close()`. `.nativeRoaming` conformers keep the SAME stream open
    /// across `suspend()`/`resume()` so the session layer's output bridge
    /// survives backgrounding. Single consumer: multiple iterators
    /// compete.
    var output: AsyncStream<Data> { get async }

    /// How this instance behaves across `suspend()`/`resume()`.
    var resumeStrategy: ResumeStrategy { get }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError)
    func send(_ bytes: Data) async throws(TransportError)

    /// Fire-and-forget per RFC 4254 §6.7 semantics; zero/negative
    /// dimensions are ignored by conformers.
    func resize(cols: Int, rows: Int) async

    /// Prepare for app backgrounding. `.rehandshake` conformers close;
    /// `.nativeRoaming` conformers keep the server-side session alive.
    func suspend() async

    /// Reattach after `suspend()`. Only `.nativeRoaming` conformers may
    /// succeed; everyone else throws ``TransportError/resumeUnsupported``.
    func resume() async throws(TransportError)

    /// Terminal, idempotent, finishes `output`.
    func close() async
}

extension TerminalTransport {
    public var resumeStrategy: ResumeStrategy { .rehandshake }

    public func suspend() async {
        await close()
    }

    public func resume() async throws(TransportError) {
        throw .resumeUnsupported
    }

    /// Bridges an input byte stream into ``send(_:)``, propagating
    /// flow-control backpressure to the producer. Returns when the input
    /// stream finishes; throws the first typed send failure.
    public func pipe(input: AsyncStream<Data>) async throws(TransportError) {
        for await bytes in input {
            try await send(bytes)
        }
    }
}
