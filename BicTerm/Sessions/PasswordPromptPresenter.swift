import BicTermCore
import Foundation
import Observation

/// Continuations are owned by the originating scene, not by the connection:
/// multiple windows may authenticate to the same saved endpoint concurrently.
@MainActor
@Observable
final class PasswordPromptPresenter: SSHPasswordPrompting {
    private(set) var requests: [String: SSHPasswordRequest] = [:]
    private(set) var errors: [String: String] = [:]
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private let passwordStore: any PasswordStoring
    var isSceneAvailable: (String) -> Bool = { _ in false }

    init(passwordStore: any PasswordStoring) {
        self.passwordStore = passwordStore
    }

    func promptForPassword(_ request: SSHPasswordRequest) async -> String? {
        guard let sceneID = request.sceneID, isSceneAvailable(sceneID), !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancel(sceneID: sceneID)
                continuations[request.id] = continuation
                requests[sceneID] = request
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request: request) }
        }
    }

    func connect(request: SSHPasswordRequest, password: String, remember: Bool) async {
        guard let sceneID = request.sceneID, requests[sceneID]?.id == request.id else { return }
        if remember, let tag = request.saveTag {
            do {
                try await passwordStore.save(password, for: tag)
            } catch {
                errors[sceneID] = "Couldn't save the password on this device. Retry or turn off Save password in Keychain."
                return
            }
        }
        guard requests[sceneID]?.id == request.id else { return }
        requests[sceneID] = nil
        errors[sceneID] = nil
        continuations.removeValue(forKey: request.id)?.resume(returning: password)
    }

    func cancel(sceneID: String) {
        guard let request = requests[sceneID] else { return }
        cancel(request: request)
    }

    func cancel(request: SSHPasswordRequest) {
        if let sceneID = request.sceneID, requests[sceneID]?.id == request.id {
            requests[sceneID] = nil
            errors[sceneID] = nil
        }
        continuations.removeValue(forKey: request.id)?.resume(returning: nil)
    }
}
