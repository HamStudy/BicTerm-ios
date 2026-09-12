import Foundation

/// Publish the reason before finishing output so its consumer cannot race an
/// actor hop from the NIO event loop. Both close callbacks may run; first wins.
final class SessionTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: TransportCloseReason?

    var reason: TransportCloseReason {
        lock.lock()
        defer { lock.unlock() }
        return recorded ?? .connectionLost
    }

    func record(_ reason: TransportCloseReason) {
        lock.lock()
        defer { lock.unlock() }
        if recorded == nil { recorded = reason }
    }
}
