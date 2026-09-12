import SwiftUI
import UIKit

extension View {
    func sceneAppearance(_ preference: AppearancePreference) -> some View {
        preferredColorScheme(preference.colorSchemeOverride)
            .background(SystemAppearanceResetter(followsSystem: preference == .system))
    }
}

/// On iOS 26, passing nil can leave SwiftUI's previous style on both the
/// UIWindowScene trait overrides and its presentation controllers. Clear those
/// pins for System so automatic device changes propagate naturally again.
private struct SystemAppearanceResetter: UIViewRepresentable {
    let followsSystem: Bool

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        guard view.followsSystem != followsSystem else { return }
        view.followsSystem = followsSystem
        view.resetSystemAppearance()
    }

    final class Probe: UIView {
        var followsSystem = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resetSystemAppearance()
        }

        func resetSystemAppearance() {
            guard followsSystem else { return }
            // Let SwiftUI finish applying presentation preferences first.
            Task { @MainActor [weak self] in
                guard let self, self.followsSystem, let window = self.window else { return }
                window.windowScene?.traitOverrides.remove(UITraitUserInterfaceStyle.self)
                var controller = window.rootViewController
                while let current = controller {
                    current.overrideUserInterfaceStyle = .unspecified
                    controller = current.presentedViewController
                }
            }
        }
    }
}
