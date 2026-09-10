import Foundation

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

    /// Full close. Terminal and idempotent.
    func close() async
}
