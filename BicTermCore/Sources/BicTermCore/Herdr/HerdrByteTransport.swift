import Foundation

/// How the remote side of a ``HerdrByteTransport`` ended, observed after
/// ``HerdrByteTransport/inboundBytes()`` finishes (doc §6.3 taxonomy): the
/// exec exit status distinguishes a clean EOF (exit 0) from an abnormal
/// remote end (server shutdown), and a channel death without status is a
/// network loss.
public enum HerdrTransportTermination: Sendable, Equatable {
    /// The remote command exited with the given status.
    case exited(Int)
    /// The channel died without delivering an exit status.
    case failed
    /// The channel was closed locally before a remote end was observed.
    case closedLocally
    /// No termination was observable within the caller's bound.
    case unknown
}

/// The transport seam the herdr client core sees (integration doc §5):
/// an ordered duplex byte stream. Conformers carry herdr's framed binary
/// protocol — bytes are OPAQUE: no UTF-8 decoding, no newline
/// normalization, ever.
public protocol HerdrByteTransport: Sendable {
    /// Writes bytes to the remote side. Suspends under flow control
    /// instead of queueing unbounded writes.
    func write(_ bytes: Data) async throws

    /// Inbound stdout bytes. Bounded buffering; overflow is surfaced as an
    /// error, never silent loss. Single consumer; finishes on remote EOF
    /// or `close()`.
    func inboundBytes() -> AsyncThrowingStream<Data, Error>

    /// Write half-close (SSH EOF): signals no further client frames.
    func closeWrite() async throws

    /// How the remote side ended; observed after ``inboundBytes()``
    /// finishes. A formal requirement so existential dispatch reaches the
    /// conformer's implementation (an extension-only default would always
    /// answer `.unknown`).
    func termination() async -> HerdrTransportTermination

    /// Full close. Terminal and idempotent.
    func close() async
}

public extension HerdrByteTransport {
    /// Default for conformers that cannot observe a remote exit status.
    func termination() async -> HerdrTransportTermination { .unknown }
}
