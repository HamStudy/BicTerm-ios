import SwiftUI
import XCTest

@testable import BicTerm

/// Dark-first invariant: every view hierarchy hosted in the app must resolve
/// `ColorScheme.dark`, so light OS appearances never flip SwiftUI's default
/// materials (list rows, form cells) under dark-palette token text. A bare,
/// unstyled probe resolves the ambient scheme — F3's defect made it `.light`.
@MainActor
final class AppearanceRegressionTests: XCTestCase {

    private struct SchemeProbe: View {
        @Environment(\.colorScheme) var scheme
        let sink: (ColorScheme) -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { sink(scheme) }
        }
    }

    private func resolvedScheme(styled: Bool) -> ColorScheme? {
        var resolved: ColorScheme?
        let probe = SchemeProbe { resolved = $0 }
        let host = UIHostingController(
            rootView: styled ? AnyView(probe.terminalStyle()) : AnyView(probe)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(1.5)
        while resolved == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        window.isHidden = true
        window.rootViewController = nil
        return resolved
    }

    func testUnstyledProbeNeverResolvesLightInsideAppProcess() {
        XCTAssertEqual(
            resolvedScheme(styled: false), .dark,
            "bare view hierarchies must stay dark; a light resolution means terminalStyle lost its scheme pin"
        )
    }

    func testTerminalStyledProbeResolvesDark() {
        XCTAssertEqual(
            resolvedScheme(styled: true), .dark,
            "terminalStyle must pin .preferredColorScheme(.dark)"
        )
    }
}
