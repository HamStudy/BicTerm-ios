import Foundation
import NIOCore
import NIOSSH

// MARK: - Pipeline factory

/// Single construction point for the client pipeline configuration so the
/// no-forwarding posture is auditable and testable in one place.
enum SSHClientPipelineFactory {
    /// Security: rejects EVERY server-initiated channel open with
    /// SSH_MSG_CHANNEL_OPEN_FAILURE. In NIOSSH 0.15.0 a `nil` initializer
    /// still accepts inbound channels (SSHChildChannel.swift:455 falls back
    /// to a succeeded future), so an explicit reject-all is required.
    static func rejectAllInboundChildChannels(
        channel: any Channel,
        channelType: SSHChannelType
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
    }

    /// No `GlobalRequestDelegate` is installed: the NIOSSH default delegate
    /// rejects all tcpip-forward requests (GlobalRequestDelegate.swift:33-44).
    static func makeConfiguration(
        userAuthDelegate: any NIOSSHClientUserAuthenticationDelegate,
        serverAuthDelegate: any NIOSSHClientServerAuthenticationDelegate
    ) -> SSHClientConfiguration {
        SSHClientConfiguration(
            userAuthDelegate: userAuthDelegate,
            serverAuthDelegate: serverAuthDelegate
        )
    }
}

// MARK: - Host key verification delegate

/// Bridges NIOSSH's event-loop host-key callback to T4's async
/// ``HostKeyVerifier``. Typed ``SSHTransportError`` failures are failed
/// straight into the validation promise; the transport recovers them from
/// the pipeline's error recorder when connection setup unwinds.
final class VerifyingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    // @unchecked Sendable: NIOSSH invokes the delegate only on the
    // connection's EventLoop; all stored properties are immutable and the
    // verifier is an actor. EventLoopPromise completion is thread-safe.
    private let host: String
    private let port: Int
    private let verifier: HostKeyVerifier

    init(host: String, port: Int, verifier: HostKeyVerifier) {
        self.host = host
        self.port = port
        self.verifier = verifier
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // "algorithm base64-wire-blob" — split and decode BEFORE hopping
        // actors so only value types cross.
        let components = String(openSSHPublicKey: hostKey).split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard components.count == 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            validationCompletePromise.fail(SSHTransportError.unreachable)
            return
        }
        let algorithm = String(components[0])
        let host = self.host
        let port = self.port
        let verifier = self.verifier

        Task {
            do {
                switch try await verifier.verify(host: host, port: port, key: blob, algorithm: algorithm) {
                case .trusted:
                    validationCompletePromise.succeed(())
                case let .requiresTrust(fingerprint, algorithm, publicKeyData):
                    validationCompletePromise.fail(SSHTransportError.requiresTrust(
                        fingerprint: fingerprint,
                        algorithm: algorithm,
                        publicKeyData: publicKeyData
                    ))
                case let .rejected(.hostKeyChanged(host, port, oldFingerprint, newFingerprint)):
                    validationCompletePromise.fail(SSHTransportError.hostKeyChanged(
                        host: host,
                        port: port,
                        oldFingerprint: oldFingerprint,
                        newFingerprint: newFingerprint
                    ))
                }
            } catch {
                // Persistence failure during trust-store access: fail closed.
                validationCompletePromise.fail(SSHTransportError.unreachable)
            }
        }
    }
}

// MARK: - User authentication delegate

/// Offers exactly one private key, exactly once. A second callback means the
/// server rejected the key; the connection is then failed with the typed
/// ``SSHTransportError/authenticationFailed``.
final class SingleKeyUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    // @unchecked Sendable: invoked only on the connection's EventLoop;
    // `didOffer` is exclusively mutated there. `key` is an opaque Sendable
    // signing handle, not key material.
    private let username: String
    private let key: NIOSSHPrivateKey
    private var didOffer = false

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOffer, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        didOffer = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: key))
        ))
    }
}

/// Offers exactly one stored password, exactly once (RFC 4252 `password`
/// method). A second callback means the server rejected the password; the
/// connection is then failed with the typed
/// ``SSHTransportError/authenticationFailed``. Servers advertising only
/// `publickey` get the same typed failure without any offer being sent.
final class PasswordUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    // @unchecked Sendable: invoked only on the connection's EventLoop;
    // `didOffer` is exclusively mutated there.
    private let username: String
    private let password: String
    private var didOffer = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOffer, availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        didOffer = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        ))
    }
}

// MARK: - Error recorder

/// Terminal handler on the parent connection channel. Records the FIRST
/// error flowing through the pipeline (host-key rejection, auth failure)
/// so the transport can map otherwise-opaque channel-creation failures
/// (`creatingChannelAfterClosure`) back to typed errors.
final class TransportErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined; `firstError` is read only via
    // `recordedError()` which hops onto that same loop.
    typealias InboundIn = Any

    private var firstError: Error?
    private var eventLoop: (any EventLoop)?

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if firstError == nil {
            firstError = error
        }
        context.close(promise: nil)
    }

    func recordedError() async -> Error? {
        guard let eventLoop else { return nil }
        return try? await eventLoop.submit { self.firstError }.get()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
    }

    // handlerRemoved intentionally keeps `eventLoop`: the transport reads
    // the recorded error AFTER the channel has been torn down, while the
    // loop's group is still alive.
}

// MARK: - Session channel handler

/// Session child-channel handler. Inbound: unwraps `SSHChannelData` into
/// `Data` chunks delivered to the transport's output stream, and tracks
/// FIFO success/failure replies for `wantReply` channel requests (pty-req,
/// shell). Outbound: wraps `Data` writes into `SSHChannelData`.
final class SessionChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined. Continuations/promises are
    // resumed from that loop only; resuming them is thread-safe.
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Data
    typealias OutboundOut = SSHChannelData

    /// SSH packets are capped at ~32 KiB; chunk defensively so the output
    /// stream's 32-element buffer bounds queued output at ~1 MiB. Overflow
    /// policy is `.bufferingNewest`: the OLDEST queued chunks are dropped.
    static let maximumChunkBytes = 32 * 1024

    private let onOutput: @Sendable (Data) -> Void
    private let onClosed: @Sendable () -> Void
    private var requestWaiters: [EventLoopPromise<Void>] = []
    private var writabilityWaiters: [CheckedContinuation<Void, Never>] = []
    private var context: ChannelHandlerContext?

    init(onOutput: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable () -> Void) {
        self.onOutput = onOutput
        self.onClosed = onClosed
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
        var slice = buffer
        while slice.readableBytes > 0 {
            let length = min(slice.readableBytes, Self.maximumChunkBytes)
            guard let chunk = slice.readSlice(length: length) else { break }
            onOutput(Data(chunk.readableBytesView))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !requestWaiters.isEmpty {
                requestWaiters.removeFirst().succeed(())
            }
        case is ChannelFailureEvent:
            if !requestWaiters.isEmpty {
                requestWaiters.removeFirst().fail(SSHTransportError.channelDenied)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, !writabilityWaiters.isEmpty {
            let waiters = writabilityWaiters
            writabilityWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(error: SSHTransportError.channelDenied)
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error: SSHTransportError.unreachable)
        onClosed()
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    // MARK: Actor-facing API (all hop onto the channel's EventLoop)

    func isWritable() async -> Bool {
        guard let context else { return false }
        return (try? await context.eventLoop.submit { context.channel.isWritable }.get()) ?? false
    }

    /// Suspends until the channel becomes writable again.
    func waitUntilWritable() async {
        guard let context else { return }
        let onLoop: Bool = context.eventLoop.inEventLoop
        await withCheckedContinuation { continuation in
            if onLoop {
                self.writabilityWaiters.append(continuation)
            } else {
                context.eventLoop.execute {
                    if context.channel.isWritable {
                        continuation.resume()
                    } else {
                        self.writabilityWaiters.append(continuation)
                    }
                }
            }
        }
    }

    /// Registers a FIFO waiter, THEN fires the request, both on the channel's
    /// EventLoop — the waiter is guaranteed to be installed before a reply
    /// (success/failure) can be processed.
    func sendRequestExpectingSuccess(_ request: some Sendable) async throws(SSHTransportError) {
        guard let context else { throw .channelDenied }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.eventLoop.execute {
                    let promise = context.eventLoop.makePromise(of: Void.self)
                    promise.futureResult.whenComplete { result in
                        continuation.resume(with: result)
                    }
                    self.requestWaiters.append(promise)
                    context.channel.triggerUserOutboundEvent(request, promise: nil)
                }
            }
        } catch let error as SSHTransportError {
            throw error
        } catch {
            throw .channelDenied
        }
    }

    private func failAll(error: SSHTransportError) {
        let requests = requestWaiters
        requestWaiters.removeAll()
        for promise in requests {
            promise.fail(error)
        }
        if !writabilityWaiters.isEmpty {
            let waiters = writabilityWaiters
            writabilityWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

// MARK: - SSHChannelData <-> ByteBuffer wrapper

/// Duplex adapter installed on `direct-tcpip` child channels so that a
/// nested `NIOSSHHandler` (T9 ProxyJump) can run a full SSH handshake over
/// the channel: inbound `SSHChannelData` becomes `ByteBuffer`, outbound
/// `ByteBuffer` becomes `SSHChannelData`.
final class SSHChannelDataByteBufferWrapper: ChannelDuplexHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined, no mutable state.
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case let .byteBuffer(buffer) = message.data else {
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}
