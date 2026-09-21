import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// `direct-tcpip` channel factory (T9 ProxyJump) on ``SSHTransport``, split
/// out so the core session-lifecycle file stays reviewable on its own.
extension SSHTransport {
    /// Opens a `direct-tcpip` channel (T9 ProxyJump). The returned channel
    /// already carries the `SSHChannelData`↔`ByteBuffer` adapter, so a
    /// nested `NIOSSHHandler` can handshake over it directly.
    public func openDirectTCPIPChannel(
        toHost host: String,
        port: Int
    ) async throws(SSHTransportError) -> SSHChannelHandle {
        guard let parent = connectionChannel, parent.isActive else { throw .channelDenied }
        guard port > 0, port <= Int(UInt16.max) else { throw .channelDenied }

        let originator: SocketAddress
        do {
            originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        } catch {
            throw .channelDenied
        }
        let target = SSHChannelType.DirectTCPIP(
            targetHost: host,
            targetPort: port,
            originatorAddress: originator
        )

        do {
            let child = try await openChildChannel(on: parent, type: .directTCPIP(target)) { channel, channelType in
                guard case .directTCPIP = channelType else {
                    return channel.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SSHChannelDataByteBufferWrapper())
                }
            }
            return SSHChannelHandle(channel: child)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? SSHTransportError {
                throw error
            } else {
                throw .channelDenied
            }
        }
    }
}
