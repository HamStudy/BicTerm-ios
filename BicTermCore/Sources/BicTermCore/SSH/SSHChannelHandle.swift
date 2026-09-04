import Foundation
import NIOCore

/// Handle to an open SSH child channel. The underlying NIO `Channel` is
/// module-internal: T8 (agent bridge) and T9 (ProxyJump) consume it from
/// within BicTermCore; no NIO type escapes the public API.
public struct SSHChannelHandle: Sendable {
    // Channel is `_NIOPreconcurrencySendable` (NIO >= 2.60): thread-safe to
    // pass between isolation domains, all operations are funnelled onto its
    // EventLoop by the pipeline.
    let channel: any Channel

    init(channel: any Channel) {
        self.channel = channel
    }

    public var isActive: Bool {
        channel.isActive
    }
}
