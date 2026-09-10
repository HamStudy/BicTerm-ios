import Foundation
import NIOCore
import NIOSSH

/// Session child-channel handler for a non-PTY exec channel (T15).
///
/// Inbound: splits `SSHChannelData` by type — `.channel` → stdout,
/// `.stdErr` → stderr — into the shared ``ExecChannelCore`` (re-sliced to
/// ≤32 KiB so per-stream buffer bounds stay computable; the byte sequence
/// is untouched — no decoding, no newline normalization). Remote EOF
/// (`ChannelEvent.inputClosed`, enabled via `allowRemoteHalfClosure`)
/// finishes both streams in order. `ExitStatus` is recorded for
/// ``SSHExecSession/termination()``.
///
/// Outbound: wraps `Data` writes into `SSHChannelData(type: .channel)`.
/// Request replies (`wantReply` exec) are tracked FIFO like
/// `SessionChannelHandler`.
final class ExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined; async API hops onto that loop.
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Data
    typealias OutboundOut = SSHChannelData

    /// Mirrors `SessionChannelHandler.maximumChunkBytes`: SSH packets cap
    /// at ~32 KiB; re-slicing inbound buffers keeps the core's
    /// bytes-per-chunk bound uniform.
    static let maximumChunkBytes = 32 * 1024

    let core: ExecChannelCore
    private var requestWaiters: [EventLoopPromise<Void>] = []
    private var writabilityWaiters: [CheckedContinuation<Void, Never>] = []
    private var context: ChannelHandlerContext?

    init(core: ExecChannelCore) {
        self.core = core
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = message.data else { return }
        let stream: ExecChannelCore.StreamKind = message.type == .channel ? .stdout : .stderr
        var slice = buffer
        while slice.readableBytes > 0 {
            let length = min(slice.readableBytes, Self.maximumChunkBytes)
            guard let chunk = slice.readSlice(length: length) else { break }
            core.offer(Data(chunk.readableBytesView), on: stream)
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
                requestWaiters.removeFirst().fail(TransportError.channelDenied)
            }
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            core.recordExitStatus(exitStatus.exitStatus)
        case ChannelEvent.inputClosed:
            // Remote EOF: no more inbound data, in stream order.
            core.finishStreams()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        core.readCycleCompleted()
        context.fireChannelReadComplete()
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
        failRequestWaiters(TransportError.channelDenied)
        resumeWritabilityWaiters()
        core.channelEnded()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failRequestWaiters(TransportError.unreachable)
        resumeWritabilityWaiters()
        core.channelEnded()
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    // MARK: Actor-facing API (hop onto the channel's EventLoop)

    func isWritable() async -> Bool {
        guard let context else { return false }
        return (try? await context.eventLoop.submit { context.channel.isWritable }.get()) ?? false
    }

    func waitUntilWritable() async {
        guard let context else { return }
        let onLoop = context.eventLoop.inEventLoop
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

    /// FIFO `wantReply` tracking, identical discipline to
    /// `SessionChannelHandler.sendRequestExpectingSuccess`: the waiter is
    /// registered on the EventLoop BEFORE the request fires.
    func sendRequestExpectingSuccess(_ request: some Sendable) async throws(TransportError) {
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
        } catch let error as TransportError {
            throw error
        } catch {
            throw .channelDenied
        }
    }

    private func failRequestWaiters(_ error: TransportError) {
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.fail(error)
        }
    }

    private func resumeWritabilityWaiters() {
        guard !writabilityWaiters.isEmpty else { return }
        let waiters = writabilityWaiters
        writabilityWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
