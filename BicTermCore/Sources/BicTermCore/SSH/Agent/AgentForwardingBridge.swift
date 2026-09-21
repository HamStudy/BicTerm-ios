import Foundation
import NIOCore
import NIOSSH

/// Wires OpenSSH agent forwarding for one SSH session: installs the inbound
/// `auth-agent@openssh.com` channel acceptor before connect, sends
/// `auth-agent-req@openssh.com` after connect (wantReply: false — OpenSSH
/// parity: denial is non-fatal and generates no reply event, so it cannot
/// race the session channel's success/failure reply tracker), then serves
/// the read-only agent protocol on each accepted agent channel.
///
/// Every sign request goes through the authorization service and is signed
/// strictly for the exact requested public blob; anything else gets
/// SSH_AGENT_FAILURE.
public actor AgentForwardingBridge {
    private let keyProvider: any AgentKeyProvider
    private let authorizer: AgentAuthorizationService
    private let sessionID: String
    private let host: String

    public init(
        keyProvider: any AgentKeyProvider,
        authorizer: AgentAuthorizationService,
        sessionID: String,
        host: String
    ) {
        self.keyProvider = keyProvider
        self.authorizer = authorizer
        self.sessionID = sessionID
        self.host = host
    }

    /// Registers the agent-channel acceptor. Must be called BEFORE
    /// `SSHTransport.connect` — the inbound initializer is captured when the
    /// NIOSSHHandler is built. When a bridge is installed, `connect` itself
    /// sends `auth-agent-req@openssh.com` (wantReply: false — OpenSSH
    /// parity: denial is non-fatal and generates no reply event, so it
    /// cannot race the session channel's success/failure reply tracker)
    /// before pty-req/shell, so the remote shell gets SSH_AUTH_SOCK.
    public func install(on transport: SSHTransport) async {
        await transport.installAgentChannelInitializer { [self] channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(AgentChannelHandler(bridge: self))
            }
        }
    }

    /// One decoded request → one framed response. Never throws: every
    /// failure mode maps to SSH_AGENT_FAILURE so a broken request can only
    /// ever deny service to itself.
    public func respond(to message: SSHAgentMessage) async -> Data {
        switch message {
        case .requestIdentities:
            guard let keys = try? await keyProvider.publicKeys() else {
                return SSHAgentCodec.encodeFailure()
            }
            return SSHAgentCodec.encodeIdentitiesAnswer(
                keys.map { SSHAgentIdentity(blob: $0.publicKeyBlob, comment: $0.label) }
            )
        case let .signRequest(keyBlob, data, _):
            // Flags are RSA-SHA2 hints (PROTOCOL.agent); we hold no RSA keys,
            // and for Ed25519/ECDSA they do not change the signature scheme.
            guard let keys = try? await keyProvider.publicKeys(),
                  let metadata = keys.first(where: { $0.publicKeyBlob == keyBlob }) else {
                return SSHAgentCodec.encodeFailure()
            }
            // Capture the interactivity generation BEFORE authorization: the
            // pre-enqueue revalidation below must reject any flow that crossed
            // a background transition (prompt wait, cached approval, or the
            // signing await itself).
            let generation = authorizer.currentAuthorizationGeneration
            let authorized = await authorizer.authorize(
                AgentAuthorizationRequest(
                    sessionID: sessionID,
                    host: host,
                    keyFingerprint: metadata.fingerprint,
                    publicKeyBlob: keyBlob
                )
            )
            guard authorized else {
                return SSHAgentCodec.encodeFailure()
            }
            do {
                let signature = try await keyProvider.sign(data: data, publicKeyBlob: keyBlob)
                // Pre-enqueue revalidation: the authorization decision and
                // the signature must belong to the same foreground span. A
                // background transition during the prompt or the signing
                // invalidates the response — FAILURE, never a signature.
                guard authorizer.isAuthorizationValid(generation: generation) else {
                    return SSHAgentCodec.encodeFailure()
                }
                let blob = try SSHAgentCodec.signatureBlob(for: signature)
                return SSHAgentCodec.encodeSignResponse(signatureBlob: blob)
            } catch {
                return SSHAgentCodec.encodeFailure()
            }
        }
    }
}

/// EventLoop-confined handler on an inbound `auth-agent@openssh.com` child
/// channel. Requests are processed SERIALLY (one in flight per channel) so
/// authorization prompts and signatures cannot interleave or reorder.
/// Bounded: at most 64 queued requests (overflow gets an immediate FAILURE)
/// and at most 1000 requests total before the channel is closed.
final class AgentChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined — `codec`, `queue`,
    // `processing`, `totalRequests` and `context` are only touched on the
    // channel's EventLoop (channelRead/pump/loop.execute callbacks). The
    // bridge is an actor; crossing into it suspends safely.
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    static let maximumQueuedRequests = 64
    static let maximumTotalRequests = 1000

    private let bridge: AgentForwardingBridge
    private var codec = SSHAgentCodec()
    private var queue: [SSHAgentMessage] = []
    private var processing = false
    private var totalRequests = 0
    private var context: ChannelHandlerContext?

    init(bridge: AgentForwardingBridge) {
        self.bridge = bridge
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case let .byteBuffer(buffer) = message.data else {
            return
        }
        let messages: [SSHAgentMessage]
        do {
            messages = try codec.feed(Data(buffer.readableBytesView))
        } catch {
            // Codec errors are terminal: no resync possible — close.
            context.close(promise: nil)
            return
        }
        for decoded in messages {
            enqueue(decoded, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        queue.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        queue.removeAll()
        context.close(promise: nil)
    }

    private func enqueue(_ message: SSHAgentMessage, context: ChannelHandlerContext) {
        totalRequests += 1
        guard totalRequests <= Self.maximumTotalRequests else {
            context.close(promise: nil)
            return
        }
        guard queue.count < Self.maximumQueuedRequests else {
            write(SSHAgentCodec.encodeFailure(), context: context)
            return
        }
        queue.append(message)
        pump(context: context)
    }

    private func pump(context: ChannelHandlerContext) {
        guard !processing, !queue.isEmpty else { return }
        processing = true
        let message = queue.removeFirst()
        let loop = context.eventLoop
        Task {
            let response = await bridge.respond(to: message)
            loop.execute {
                if let context = self.context {
                    self.write(response, context: context)
                }
                self.processing = false
                if let context = self.context {
                    self.pump(context: context)
                }
            }
        }
    }

    private func write(_ bytes: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: nil
        )
    }
}
