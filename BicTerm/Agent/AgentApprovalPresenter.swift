import BicTermCore
import SwiftUI
import UIKit

/// Where a pending agent-approval sheet is presented. Exactly one target is
/// chosen per request (single MainActor decision — no presentation race).
enum AgentPromptTarget: Equatable {
    /// The terminal scene (window) whose session originated the request.
    case scene(UUID)
    /// The connection list window, when no live scene matches.
    case mainWindow
}

/// Routing decision for a pending approval request.
struct AgentPromptRouting: Equatable {
    let target: AgentPromptTarget
    let sessionDisplayName: String
}

/// T8 ``AgentAuthorizationPrompt`` UI implementation: publishes the pending
/// request for a SwiftUI sheet and awaits the user's decision.
///
/// The sheet shows ONLY metadata — key fingerprint, requesting host, and the
/// originating session. The wire-format public key blob stays inside the
/// service; it never reaches the view layer.
@MainActor
@Observable
final class AgentApprovalPresenter: AgentAuthorizationPrompt {
    private(set) var pendingRequest: AgentAuthorizationRequest?
    private(set) var routing: AgentPromptRouting?
    private(set) var promptCount = 0

    private var continuation: CheckedContinuation<AgentAuthorizationDecision, Never>?
    private var resolveRouting: @MainActor (String) -> AgentPromptRouting

    /// - Parameter resolveRouting: Maps the bridge session ID of an incoming
    ///   request to its presentation target (which scene, or the main window).
    init(resolveRouting: @escaping @MainActor (String) -> AgentPromptRouting) {
        self.resolveRouting = resolveRouting
    }

    /// Re-wires routing after the owning store finishes construction (the
    /// routing closure needs the store's descriptors, which do not exist
    /// while the presenter is being injected into the service).
    func configureRouting(_ resolver: @escaping @MainActor (String) -> AgentPromptRouting) {
        resolveRouting = resolver
    }

    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision {
        // The service bounds concurrency to one prompt at a time; a second
        // arrival here would be a contract violation — deny rather than hang.
        guard continuation == nil else { return .deny }

        promptCount += 1
        let decision = await withCheckedContinuation { (c: CheckedContinuation<AgentAuthorizationDecision, Never>) in
            pendingRequest = request
            routing = resolveRouting(request.sessionID)
            continuation = c
        }
        return decision
    }

    /// Resumes the pending prompt (idempotent — a late tap after dismissal
    /// must not resume twice).
    func resolve(_ decision: AgentAuthorizationDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
        pendingRequest = nil
        routing = nil
    }

    /// Denies the pending prompt when it is presented by (or belongs to) the
    /// given scene — used when that scene's session closes mid-prompt so the
    /// service's single prompt slot is never leaked.
    func denyPendingIfTargeting(scene descriptorID: UUID) {
        if isTargeting(scene: descriptorID) {
            resolve(.deny)
        }
    }

    /// Denies the pending prompt if it was routed to the main window.
    func denyPendingIfMainWindow() {
        if routing?.target == .mainWindow {
            resolve(.deny)
        }
    }

    func isTargeting(scene descriptorID: UUID) -> Bool {
        if case .scene(let id) = routing?.target, id == descriptorID {
            return true
        }
        return false
    }
}

/// Production ``LockStateProvider``: interactive only while the application
/// is foreground-active. Notification-updated so the sync `isInteractive`
/// check never touches UIKit off the main thread.
final class ApplicationLockStateProvider: LockStateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var applicationIsActive: Bool

    init() {
        let state = MainActor.assumeIsolated {
            UIApplication.shared.applicationState
        }
        applicationIsActive = state == .active

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
    }

    var isInteractive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return applicationIsActive
    }

    private func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        applicationIsActive = active
    }
}

/// Modal approval sheet: fingerprint, requesting host, and session only.
/// Never renders or exports key material.
struct AgentApprovalSheetView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let request: AgentAuthorizationRequest
    let sessionDisplayName: String
    let onDecision: (AgentAuthorizationDecision) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: spacing.md) {
                Label("SSH Agent Sign Request", systemImage: "key.horizontal.fill")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .accessibilityIdentifier("agent-approval-sheet")

                metadataRow(
                    title: "Key Fingerprint",
                    value: request.keyFingerprint,
                    identifier: "agent-fingerprint"
                )

                metadataRow(
                    title: "Requesting Host",
                    value: request.host,
                    identifier: "agent-host"
                )

                metadataRow(
                    title: "Session",
                    value: sessionDisplayName,
                    identifier: "agent-session"
                )

                Text("A remote program wants to sign data with this key. Verify the fingerprint before approving. Key material never leaves this device.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)

                Spacer(minLength: 0)

                VStack(spacing: spacing.xs) {
                    Button {
                        onDecision(.allowForSession)
                    } label: {
                        Text("Approve for this Session")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.success)
                    .accessibilityIdentifier("agent-approve-session")

                    Button {
                        onDecision(.allowOnce)
                    } label: {
                        Text("Approve Once")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.accent)
                    .accessibilityIdentifier("agent-approve-once")

                    Button(role: .destructive) {
                        onDecision(.deny)
                    } label: {
                        Text("Deny")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.error)
                    .accessibilityIdentifier("agent-deny")
                }
            }
            .padding(spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Agent Request")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func metadataRow(title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: spacing.xxxs) {
            Text(title)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Text(value)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
        .padding(spacing.xs)
        .background(colors.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
