import Foundation
import NIOCore
import NIOSSH

/// Public coordinates and an optional destination-only Keychain tag, never a secret.
public struct SSHPasswordRequest: Sendable, Identifiable {
    public let id = UUID()
    public let host: String
    public let port: Int
    public let username: String
    public let sceneID: String?
    public let saveTag: String?
}

public protocol SSHPasswordPrompting: Sendable {
    /// Nil declines authentication. Implementations must also resolve dismissed prompts.
    func promptForPassword(_ request: SSHPasswordRequest) async -> String?
}

public extension Connection {
    /// Separate from the signing-key reference; no secret or extra model field is persisted.
    var promptedPasswordTag: String { "bicterm.pwd.conn.\(id.uuidString)" }
}

/// Offers each credential once. The mutable offer flags stay on NIO's event loop;
/// only immutable values cross into the task that waits for Keychain/UI work.
final class CascadeUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let key: NIOSSHPrivateKey?
    private let request: SSHPasswordRequest
    private let passwordTag: String?
    private let passwordStore: any PasswordStoring
    private let prompt: (any SSHPasswordPrompting)?
    private var offeredKey = false
    private var offeredPassword = false
    private var resolutionTask: Task<Void, Never>?

    func channelInactive(context: ChannelHandlerContext) {
        resolutionTask?.cancel()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        resolutionTask?.cancel()
    }

    init(host: String, port: Int, username: String, key: NIOSSHPrivateKey?,
         passwordTag: String?, canRemember: Bool,
         passwordStore: any PasswordStoring, prompt: (any SSHPasswordPrompting)?) {
        self.key = key
        self.passwordTag = passwordTag
        self.passwordStore = passwordStore
        self.prompt = prompt
        self.request = SSHPasswordRequest(host: host, port: port, username: username,
                                          sceneID: SessionTransportContext.sceneID,
                                          saveTag: canRemember ? passwordTag : nil)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let key, !offeredKey, availableMethods.contains(.publicKey) {
            offeredKey = true
            nextChallengePromise.succeed(.init(username: request.username, serviceName: "ssh-connection",
                                                offer: .privateKey(.init(privateKey: key))))
            return
        }
        guard !offeredPassword, availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        offeredPassword = true
        let request = request
        let passwordTag = passwordTag
        let passwordStore = passwordStore
        let prompt = prompt
        resolutionTask = Task {
            do {
                var password: String?
                if let passwordTag { password = try await passwordStore.password(for: passwordTag) }
                if password == nil { password = await prompt?.promptForPassword(request) }
                guard let password, !Task.isCancelled else {
                    nextChallengePromise.fail(SSHTransportError.authenticationFailed)
                    return
                }
                nextChallengePromise.succeed(.init(username: request.username, serviceName: "ssh-connection",
                                                    offer: .password(.init(password: password))))
            } catch {
                nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            }
        }
    }
}
