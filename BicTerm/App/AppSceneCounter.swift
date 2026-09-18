import UIKit

/// App-layer visibility counter over the app's connected scenes. The
/// session-close path uses it to decide whether the window losing its
/// session may dismiss: dismissing the app's LAST visible scene would
/// background the whole app, so that window must stay and fall back to
/// the connection list instead. Scene enumeration is UIKit app-layer
/// state — this helper must never move into BicTermCore.
@MainActor
enum AppSceneCounter {
    /// A scene state that renders on screen: `foregroundActive` (key,
    /// receiving events) or `foregroundInactive` (visible, not key).
    /// `.background` scenes are not visible and do not count.
    static func isVisible(_ state: UIScene.ActivationState) -> Bool {
        state == .foregroundActive || state == .foregroundInactive
    }

    /// Decision predicate for the session-close window behavior:
    /// closing a session from a window's X dismisses that window
    /// unless it is the app's last visible window. The close always
    /// originates from user interaction in that window, so its scene
    /// is visible — a visible count of 1 means it is the sole visible
    /// scene. iPhone cover mode (`supportsMultipleWindows == false`)
    /// never dismisses.
    static func shouldDismissWindow(
        supportsMultipleWindows: Bool,
        visibleWindowSceneCount: Int
    ) -> Bool {
        supportsMultipleWindows && visibleWindowSceneCount > 1
    }

    /// Number of the app's window scenes currently visible on screen.
    /// Settings and herdr windows count — any visible scene keeps the
    /// terminal window from being the last one.
    static func visibleWindowSceneCount(
        connectedScenes: Set<UIScene> = UIApplication.shared.connectedScenes
    ) -> Int {
        connectedScenes.reduce(0) { count, scene in
            guard let windowScene = scene as? UIWindowScene,
                  isVisible(windowScene.activationState) else { return count }
            return count + 1
        }
    }
}
