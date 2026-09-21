import SwiftUI
import UIKit
import XCTest
@testable import BicTerm

// MARK: - Test doubles

/// Immediately resolves every authentication with the scripted outcome.
private final class ScriptedAuthClient: OwnerAuthenticationClient, @unchecked Sendable {
    // @unchecked Sendable: test double; immutable outcome.
    private let outcome: OwnerAuthenticationOutcome

    init(outcome: OwnerAuthenticationOutcome) {
        self.outcome = outcome
    }

    func authenticate(reason: String) async -> OwnerAuthenticationOutcome { outcome }
}

/// Pends every authentication until the test releases it (FIFO), recording
/// when the call reached the client so tests can sequence around the hop.
private final class PendedAuthClient: OwnerAuthenticationClient, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private var pended: [CheckedContinuation<OwnerAuthenticationOutcome, Never>] = []
    private var startedCount = 0

    func authenticate(reason: String) async -> OwnerAuthenticationOutcome {
        lock.withLock { startedCount += 1 }
        return await withCheckedContinuation { continuation in
            lock.withLock { pended.append(continuation) }
        }
    }

    var hasStartedCall: Bool { lock.withLock { startedCount > 0 } }
    var pendingCount: Int { lock.withLock { pended.count } }

    /// Resolves the OLDEST pended call — the stale-completion path releases
    /// the call that started FIRST.
    func releaseNext(_ outcome: OwnerAuthenticationOutcome) {
        lock.withLock {
            if !pended.isEmpty {
                pended.removeFirst().resume(returning: outcome)
            }
        }
    }
}

// MARK: - Hit-test probe hosting

/// A plain UIView probe: the cover is present at the window's center
/// exactly when the window's hit test does NOT resolve to the probe
/// (the opaque cover intercepts the hit).
private final class ProbeView: UIView {}

private struct HitTestProbe: UIViewRepresentable {
    let onMake: @MainActor (ProbeView) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        onMake(view)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    /// A plain UIView has no intrinsic size — SwiftUI would size the
    /// probe to zero and the window's center hit would never resolve to
    /// it. Accept the proposal so the probe fills the host.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProbeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Scene-root-shaped host: probe content with the app-lock cover
/// modifier attached, exactly like the real scene roots.
private struct ProbeHost: View {
    let context: AppLockCoverContext
    let onProbe: @MainActor (ProbeView) -> Void

    var body: some View {
        HitTestProbe(onMake: onProbe)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appLockCover(context)
    }
}

// MARK: - Tests

/// T11 per-scene privacy covers: window-hosted hit-test proof that the
/// cover occludes every window while locked (including a window created
/// while already locked — no first-frame content flash), stays off for
/// inactive-without-background, rejects stale unlock completions, and
/// clears synchronously on current-generation unlock and on disable.
@MainActor
final class AppLockCoverTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        // KeepAwakeModel (built inside the cover context) mirrors its pref
        // onto the idle timer at init; keep the process-global state clean.
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func tearDown() {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    // MARK: - Helpers

    /// Polls with BOTH a synchronous run-loop pump (drives UIKit/SwiftUI
    /// layout inside the hosting view — parking in `Task.sleep` alone
    /// never lays it out) and a short suspension (releases the main
    /// actor so sibling async tasks — the authentication attempts — can
    /// run; the pump alone holds the actor and starves them).
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Self.pumpRunLoop(0.05)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Sync helper: `RunLoop` APIs are unavailable directly inside async
    /// contexts under Swift 6.
    private static func pumpRunLoop(_ duration: TimeInterval) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(duration))
    }

    private func makeContext(state: AppLockState) -> AppLockCoverContext {
        AppLockCoverContext(
            model: AppLockModel(state: state),
            fontModel: TerminalFontModel(),
            themeModel: ThemeModel(),
            osc52Model: Osc52ClipboardModel(),
            keepAwakeModel: KeepAwakeModel()
        )
    }

    /// Hosts one window whose content is the probe plus the cover
    /// modifier, and waits for the first layout (the probe attached to
    /// the window). The window joins the app's foreground scene when one
    /// exists — a scene-less window never completes its appearance
    /// transition in the test host, so the SwiftUI content inside the
    /// hosting view never lays out and the probe never attaches.
    private func hostWindow(context: AppLockCoverContext) async -> (window: UIWindow, probe: ProbeView) {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        if let scene = (UIApplication.shared.connectedScenes.first {
            ($0 as? UIWindowScene)?.activationState == .foregroundActive
        } as? UIWindowScene) {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: frame)
        }
        window.frame = frame
        var probe: ProbeView?
        window.rootViewController = UIHostingController(
            rootView: ProbeHost(context: context) { probe = $0 }
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        let hosted = await waitUntil { probe?.window === window }
        XCTAssertTrue(hosted, "probe view never hosted — window never laid out")
        return (window, probe!)
    }

    /// Cover present ⟺ the window's center hit does not resolve to the
    /// probe (the opaque cover intercepts it).
    /// Cover present ⟺ the window's center hit does not resolve to the
    /// probe (the opaque cover intercepts it).
    private func isCovered(_ window: UIWindow, probe: ProbeView) -> Bool {
        let hit = window.hitTest(
            CGPoint(x: window.bounds.midX, y: window.bounds.midY),
            with: nil
        )
        return hit !== probe
    }

    // MARK: - Two windows

    /// Two windows over one shared lock state: both cover on relock and
    /// both clear on one current-generation unlock.
    func testTwoWindowsBothCoveredWhileLocked() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let context = makeContext(state: state)
        let first = await hostWindow(context: context)
        let second = await hostWindow(context: context)

        state.enable()
        XCTAssertFalse(isCovered(first.window, probe: first.probe), "enabling must not cover — the user is present")
        XCTAssertFalse(isCovered(second.window, probe: second.probe))

        state.noteDidEnterBackground()
        let bothCovered = await waitUntil {
            self.isCovered(first.window, probe: first.probe)
                && self.isCovered(second.window, probe: second.probe)
        }
        XCTAssertTrue(bothCovered, "both windows must cover while locked")

        await state.authenticate(reason: "unlock")
        let bothUncovered = await waitUntil {
            !self.isCovered(first.window, probe: first.probe)
                && !self.isCovered(second.window, probe: second.probe)
        }
        XCTAssertTrue(bothUncovered, "one unlock must clear both covers")
    }

    // MARK: - Late window

    /// A window created WHILE already locked is covered from its FIRST
    /// layout — the very first hit-testable content at the center is the
    /// cover, never the probe (no first-frame content flash).
    func testLateWindowCoveredFromFirstLayout() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        state.enable()
        state.noteDidEnterBackground()
        XCTAssertTrue(state.isLocked)

        let context = makeContext(state: state)
        let late = await hostWindow(context: context)

        // hostWindow already waited for the first layout; the assertion
        // runs in the same main-actor turn, so it observes that frame.
        XCTAssertTrue(
            isCovered(late.window, probe: late.probe),
            "a window created while locked must be covered from its first layout"
        )
    }

    // MARK: - Inactive without background (t10 distinction)

    /// Scene-inactive without a background transition (the system auth
    /// sheet, control center, an incoming call) must NOT cover: only a
    /// true background transition engages the lock.
    func testInactiveWithoutBackgroundDoesNotCover() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let context = makeContext(state: state)
        let hosted = await hostWindow(context: context)

        state.enable()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        Self.pumpRunLoop(0.2)

        XCTAssertFalse(state.isLocked, "inactive-without-background must not lock (t10)")
        XCTAssertFalse(
            isCovered(hosted.window, probe: hosted.probe),
            "inactive-without-background must not cover"
        )
    }

    // MARK: - Stale unlock

    /// A completion that resolves after a newer generation (the app
    /// backgrounded again mid-auth) is rejected: the cover stays. A fresh
    /// current-generation attempt then uncovers.
    func testStaleUnlockRejectedThenFreshUnlockUncovers() async {
        let client = PendedAuthClient()
        let state = AppLockState(client: client)
        let context = makeContext(state: state)
        let hosted = await hostWindow(context: context)

        state.enable()
        state.noteDidEnterBackground()  // generation 1, locked
        let covered = await waitUntil { self.isCovered(hosted.window, probe: hosted.probe) }
        XCTAssertTrue(covered)

        // Attempt A starts, then the app backgrounds again: generation 2
        // owns the UI and attempt A is stale.
        async let attemptA: Void = state.authenticate(reason: "unlock")
        let started = await waitUntil { client.hasStartedCall }
        XCTAssertTrue(started, "authentication must reach the client")
        state.noteDidEnterBackground()
        client.releaseNext(.success)
        await attemptA

        XCTAssertTrue(state.isLocked, "a stale success must not unlock")
        XCTAssertTrue(
            isCovered(hosted.window, probe: hosted.probe),
            "a stale success must not remove the cover"
        )

        // Fresh attempt in the current generation unlocks and uncovers.
        async let attemptB: Void = state.authenticate(reason: "unlock")
        let secondStarted = await waitUntil { client.pendingCount == 1 }
        XCTAssertTrue(secondStarted, "the fresh attempt must pend")
        client.releaseNext(.success)
        await attemptB

        XCTAssertFalse(state.isLocked)
        let uncovered = await waitUntil { !self.isCovered(hosted.window, probe: hosted.probe) }
        XCTAssertTrue(uncovered, "a current-generation unlock must remove the cover")
    }

    // MARK: - Disable recovery

    /// Disabling while locked is the no-authentication recovery path:
    /// the covers come off immediately.
    func testDisableWhileLockedRemovesCoversImmediately() async {
        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let context = makeContext(state: state)
        let hosted = await hostWindow(context: context)

        state.enable()
        state.noteDidEnterBackground()
        let covered = await waitUntil { self.isCovered(hosted.window, probe: hosted.probe) }
        XCTAssertTrue(covered)

        state.disable()
        let uncovered = await waitUntil(timeout: 1) { !self.isCovered(hosted.window, probe: hosted.probe) }
        XCTAssertTrue(uncovered, "disable() must remove the cover without authentication")
    }

    // MARK: - Model persistence

    /// The Settings toggle's write path persists the choice, a fresh
    /// model applies it at init (relaunch restores the user's choice),
    /// and a foreign stored value reads as OFF.
    func testModelPersistsChoiceAndAppliesItAtInit() {
        let suiteName = "applock-cover-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppLockSettings(defaults: defaults)

        let state = AppLockState(client: ScriptedAuthClient(outcome: .success))
        let model = AppLockModel(state: state, settings: settings)
        XCTAssertFalse(model.isEnabled, "app lock defaults OFF")

        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(settings.isEnabled, "the choice must persist")

        // Relaunch: a fresh model applies the persisted pref at init.
        let relaunched = AppLockModel(
            state: AppLockState(client: ScriptedAuthClient(outcome: .success)),
            settings: settings
        )
        XCTAssertTrue(relaunched.isEnabled, "a relaunch must restore the enabled choice")

        relaunched.setEnabled(false)
        XCTAssertFalse(settings.isEnabled, "disabling persists too")

        // A foreign stored value reads as OFF — a stale pref can never
        // pin the app locked.
        defaults.set("not-a-bool", forKey: "bicterm.applock.enabled")
        XCTAssertFalse(settings.isEnabled)
        settings.reset()
        XCTAssertFalse(settings.isEnabled)
    }
}
