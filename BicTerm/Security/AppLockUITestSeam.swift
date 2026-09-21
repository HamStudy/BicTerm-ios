#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only launch-controlled app-lock UI-test seam. Compiled out of
/// Release; inert without `--uitest-applock-pend`.
///
///   --uitest-applock-pend     use the pended fake owner-auth client and
///                             activate this seam (overlay below)
///   --uitest-applock-enable   enable the app lock at bootstrap
///
/// Real LAContext cannot run in simulator tests. The seam drives the
/// PRODUCTION `AppLockState` code path deterministically: a small overlay
/// window (status line + release controls) makes the model state
/// XCUITest-observable, and the overlay's release buttons resolve the
/// pended fake client with success/failure. The unlock path itself is
/// production UI — the per-scene cover's Unlock button is the single
/// trigger; this seam never requests authentication on its own.
@MainActor
enum AppLockUITestSeam {
    nonisolated static let pendArgument = "--uitest-applock-pend"
    nonisolated static let enableArgument = "--uitest-applock-enable"

    /// Pure launch-argument read and an immutable Sendable singleton:
    /// nonisolated so the nonisolated `AppLockClientFactory` can select the
    /// fake client without a main-actor hop.
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(pendArgument)
    }

    /// The single pended client shared with `AppLockClientFactory` so the
    /// overlay's release buttons resolve the calls the model actually made.
    nonisolated static let sharedClient = PendedOwnerAuthenticationClient()

    private static var activated = false
    private static var overlayWindow: UIWindow?
    private static var observers: [NSObjectProtocol] = []

    static func activateIfNeeded(state: AppLockState) {
        guard isActive, !activated else { return }
        activated = true

        if ProcessInfo.processInfo.arguments.contains(enableArgument) {
            state.enable()
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                installOverlayWindowIfNeeded(state: state)
            }
        })
        // Robustness for launches whose scene activates after (or without)
        // the application-level event: idempotent with the handler above.
        observers.append(center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                installOverlayWindowIfNeeded(state: state)
            }
        })
    }

    private static func installOverlayWindowIfNeeded(state: AppLockState) {
        // The overlay must live in the FOREGROUND scene: on iPad only the
        // active window is visible and tappable — an overlay left in a
        // covered background window stays readable in the AX tree but
        // its release buttons can never receive a tap (XCUITest taps land
        // on the foreground window). Re-parent on every activation so the
        // controls follow focus across windows.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        if let existing = overlayWindow {
            if existing.windowScene !== scene {
                existing.windowScene = scene
            }
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.frame = CGRect(
            x: 8,
            y: 60,
            width: scene.screen.bounds.width - 16,
            height: 110
        )
        let host = UIHostingController(rootView: AppLockUITestOverlayView(state: state))
        window.rootViewController = host
        // Not makeKeyAndVisible: the overlay must never steal key-window
        // status from the app's real content.
        window.isHidden = false
        overlayWindow = window
    }
}

/// The overlay surface: live model status (XCUITest reads the
/// `applock-status` label) and the pended-gate release controls.
private struct AppLockUITestOverlayView: View {
    let state: AppLockState

    var body: some View {
        VStack(spacing: 6) {
            Text(statusLine)
                .monospaced()
                .accessibilityIdentifier("applock-status")
            HStack(spacing: 12) {
                Button("Release Success") {
                    AppLockUITestSeam.sharedClient.releaseNext(.success)
                }
                .accessibilityIdentifier("applock-release-success")
                Button("Release Failure") {
                    AppLockUITestSeam.sharedClient.releaseNext(.failure)
                }
                .accessibilityIdentifier("applock-release-failure")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusLine: String {
        let auth: String
        switch state.authStatus {
        case .idle: auth = "idle"
        case .authenticating: auth = "authenticating"
        case .failed: auth = "failed"
        case .cancelled: auth = "cancelled"
        case .unavailable: auth = "unavailable"
        }
        return "applock enabled:\(state.isEnabled ? 1 : 0)"
            + " locked:\(state.isLocked ? 1 : 0)"
            + " gen:\(state.generation)"
            + " auth:\(auth)"
    }
}
#endif
