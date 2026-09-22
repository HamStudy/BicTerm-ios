import Foundation
import SwiftUI

/// UserDefaults-backed persistence for the app-lock choice (same
/// struct-over-UserDefaults convention as `KeepAwakeSettings` /
/// `ThemeSettings`). Default OFF — the app never locks until the user
/// opts in; an absent key or a foreign stored value also reads as OFF,
/// so a stale pref can never pin the app locked.
struct AppLockSettings {
    private let defaults: UserDefaults
    private let key = "bicterm.applock.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `true` only when the user explicitly enabled the app lock.
    var isEnabled: Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }

    /// Drops the stored choice; the next read returns the default (OFF).
    /// Used by UITEST setup so launch state is deterministic.
    func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// App-global app-lock preference: the single write path behind the
/// Settings Security toggle. One instance lives on `AppServices`
/// (constructed right after the `AppLockState` it wraps) so every scene
/// and the recovery sheet observe the same state. The model applies the
/// persisted preference to the policy state AT INIT — a relaunch restores
/// the user's choice before the first background transition can engage
/// the lock — and persists on every mutation.
@MainActor
@Observable
final class AppLockModel {
    private let settings: AppLockSettings

    /// The t10 policy state this model wraps (generation, relock, owner
    /// authentication). Exposed for the cover and the UI-test seam.
    let state: AppLockState

    init(state: AppLockState, settings: AppLockSettings = AppLockSettings()) {
        self.state = state
        self.settings = settings
        if settings.isEnabled {
            state.enable()
        }
    }

    /// Current preference (single source of truth: the policy state).
    /// SwiftUI observes this through the underlying `@Observable` state.
    var isEnabled: Bool { state.isEnabled }

    /// Persists and applies a new choice. Disabling is the no-auth
    /// recovery path — it clears an engaged lock, which removes every
    /// scene cover immediately.
    func setEnabled(_ enabled: Bool) {
        guard enabled != state.isEnabled else { return }
        if enabled {
            state.enable()
        } else {
            state.disable()
        }
        settings.setEnabled(enabled)
    }
}

/// Everything the cover's recovery affordance needs to present the real
/// SettingsView while locked out (owner authentication unavailable — no
/// passcode set): Settings must stay reachable so the user can disable
/// the lock without authenticating.
struct AppLockCoverContext {
    let model: AppLockModel
    let fontModel: TerminalFontModel
    let themeModel: ThemeModel
    let osc52Model: Osc52ClipboardModel
    let keepAwakeModel: KeepAwakeModel
}

/// Per-scene opaque privacy cover, attached at every scene root in
/// `BicTermApp`. DECLARATIVE and driven ONLY by `state.isLocked` — no
/// registration-gated cover logic (a registration check has a
/// first-frame content-flash hole): the cover is part of the scene's
/// view tree whenever the lock is engaged, including a window created
/// while already locked, and removal is synchronous on
/// current-generation unlock (t10's generation model rejects stale
/// completions, so `isLocked` only clears for the generation the user
/// can observe). Content beneath is hidden from accessibility while
/// covered; the cover itself offers the single unlock path (its Unlock
/// button) plus a Settings recovery affordance when owner
/// authentication cannot run.
struct AppLockCoverModifier: ViewModifier {
    let context: AppLockCoverContext

    @State private var recoveryPresented = false

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(context.model.state.isLocked)
            .overlay {
                if context.model.state.isLocked {
                    AppLockCoverView(context: context, recoveryPresented: $recoveryPresented)
                        .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $recoveryPresented) {
                AppLockRecoverySettingsSheet(context: context)
            }
    }
}

extension View {
    /// Installs the per-scene app-lock privacy cover (see
    /// `AppLockCoverModifier`). Attach at the scene root, OUTSIDE the
    /// environment injections the recovery sheet's SettingsView needs.
    func appLockCover(_ context: AppLockCoverContext) -> some View {
        modifier(AppLockCoverModifier(context: context))
    }
}

/// The cover surface: an opaque UIKit-backed blocking layer (see
/// `AppLockBlockingView`), the lock icon, the Unlock button (the single
/// unlock path), and — only when owner authentication is unavailable —
/// the Settings recovery affordance.
private struct AppLockCoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalTypography) private var typography

    let context: AppLockCoverContext
    @Binding var recoveryPresented: Bool

    var body: some View {
        let palette = TerminalColors.palette(for: colorScheme)
        ZStack {
            AppLockBlockingView(background: palette.nativeBackground)
            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(palette.dimmed)
                    .accessibilityHidden(true)
                Text("BicTerm Locked")
                    .font(typography.headline)
                    .foregroundStyle(palette.foreground)
                Button {
                    Task { await context.model.state.authenticate(reason: "Unlock BicTerm") }
                } label: {
                    Text("Unlock")
                        .font(typography.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("applock-cover-unlock")

                if context.model.state.authStatus == .unavailable {
                    Button {
                        recoveryPresented = true
                    } label: {
                        Text("Open Settings")
                            .font(typography.body)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("applock-cover-recovery")
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// UIKit-backed opaque blocking surface of the cover. SwiftUI-drawn
/// overlay content alone does NOT claim UIKit hit-testing over a
/// `UIViewRepresentable` beneath it (the SwiftTerm terminal): a plain
/// UIView sibling placed above it by the overlay's tree order
/// intercepts every touch deterministically, which is exactly the
/// privacy guarantee the cover exists to provide.
private struct AppLockBlockingView: UIViewRepresentable {
    let background: UIColor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = background
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.backgroundColor = background
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// The recovery sheet: the real SettingsView (Security section carries
/// the App Lock toggle) so a user locked out by unavailable owner
/// authentication — no passcode set on the device — can still disable
/// the lock. Disabling clears the engaged lock and every cover.
private struct AppLockRecoverySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: AppLockCoverContext

    var body: some View {
        NavigationStack {
            SettingsView(
                fontModel: context.fontModel,
                themeModel: context.themeModel,
                osc52Model: context.osc52Model,
                keepAwakeModel: context.keepAwakeModel,
                appLockModel: context.model
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("applock-recovery-done")
                }
            }
        }
        .terminalStyle()
    }
}

#if DEBUG
/// App-lock UI-test determinism (`KeepAwakeUITestLaunchControl` pattern).
/// `AppLockModel` applies the persisted preference AT INIT inside
/// `AppServices.shared`, so the reset cannot ride the post-bootstrap
/// session driver — `BicTermApp.init` calls ``apply()`` before the first
/// `AppServices.shared` touch (the same slot as the keep-awake control).
///
///   --uitest-applock-pend          this launch drives the pended fake client
///   --uitest-sessions              session-scene UI tests (backgrounding
///                                   suites) must not inherit a stale lock
///   --uitest-keep-applock-pref      deliberately preserve the pref
///                                   (persistence tests)
enum AppLockUITestLaunchControl {
    static func apply() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--uitest-keep-applock-pref"),
              arguments.contains("--uitest-applock-pend")
                || arguments.contains("--uitest-sessions")
        else { return }
        AppLockSettings().reset()
    }
}
#endif
