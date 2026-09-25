import Foundation
import GameController
import SwiftTerm
import UIKit
import os

/// T2 DEBUG observability for keyboard-styled UI (companion to SwiftTerm
/// fork hunk 16): the real-device "stuck 3-row function-key panel" defect
/// shipped no evidence, so every keyboard-frame transition and every
/// app-hosted strip creation logs here — filter Console on category
/// "keyboard-ui" (the fork logs the same category under its own
/// subsystem).
#if DEBUG
private let keyboardUILog = Logger(subsystem: "com.bicterm.app", category: "keyboard-ui")
#endif

/// UserDefaults-backed persistence for the user's EXPLICIT toolbar choice
/// (same struct-over-UserDefaults convention as `HerdrClipboardSettings`).
/// An absent key means "no explicit choice" — the hardware-keyboard
/// heuristic in ``TerminalToolbarModel`` supplies the default.
struct TerminalToolbarSettings {
    private let defaults: UserDefaults
    private let key = "bicterm.terminal.toolbar.visible"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var explicitVisibility: Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func setExplicitVisibility(_ visible: Bool) {
        defaults.set(visible, forKey: key)
    }

    func clearExplicitChoice() {
        defaults.removeObject(forKey: key)
    }
}

/// The terminal's input-surface mode — one source of truth for the
/// system keyboard, the alternate function-key panel, and the sticky
/// dismissal (K1). App-global like the toolbar visibility: every surface
/// applies the same mode.
enum TerminalInputMode: Equatable {
    /// The system software keyboard (K1 semantics).
    case keyboard
    /// SwiftTerm's 3-row function-key panel (fork hunk 17) replaces the
    /// system keyboard as the input surface.
    case functionKeys
    /// Sticky dismissal: no input surface until a terminal tap (K1).
    case hidden
}

/// App-global visibility preference for the terminal's accessory toolbar
/// (SwiftTerm's `TerminalAccessory`: esc/ctrl/tab/arrows strip).
///
/// Default: HIDDEN when a hardware keyboard is attached
/// (`GCKeyboard.coalesced != nil` — the common iPad case, where hardware
/// keys cover the strip's functions), SHOWN when only the on-screen
/// keyboard is available. Toggling from the scene chrome persists an
/// explicit choice that wins over the heuristic until cleared; keyboard
/// attach/detach re-applies the heuristic only while no explicit choice
/// exists.
@MainActor
@Observable
final class TerminalToolbarModel {
    private var settings: TerminalToolbarSettings
    private var hardwareKeyboardAttached: Bool
    nonisolated(unsafe) private var keyboardObservers: [NSObjectProtocol] = []

    private(set) var isVisible: Bool

    /// The input-surface mode (see ``TerminalInputMode``). Transient
    /// runtime state — never persisted; a fresh launch always starts
    /// with the system keyboard. Transitions:
    ///
    ///   - terminal tap when hidden → `.keyboard`
    ///   - dismiss control from keyboard/functionKeys → `.hidden`
    ///   - the function-keys toggle (strip button or scene menu):
    ///     `.keyboard` ↔ `.functionKeys`, and `.hidden` → `.functionKeys`
    ///   - a hardware keyboard attaching at runtime ends `.hidden` (the
    ///     K1 blocker would break hardware-key delivery) but deliberately
    ///     NOT `.functionKeys`: the panel is an explicit user mode,
    ///     hardware keys deliver in parallel, and the user dismisses it
    ///     through the same toggle.
    private(set) var inputMode: TerminalInputMode = .keyboard

    /// K1 view of the mode: true while no input surface is on screen.
    var keyboardHidden: Bool { inputMode == .hidden }

    /// `hardwareKeyboardAttached` is injectable so unit tests can drive the
    /// heuristic without a physical keyboard; production reads
    /// `GCKeyboard.coalesced`.
    init(
        settings: TerminalToolbarSettings = TerminalToolbarSettings(),
        hardwareKeyboardAttached: Bool = GCKeyboard.coalesced != nil
    ) {
        self.settings = settings
        self.hardwareKeyboardAttached = hardwareKeyboardAttached
        self.isVisible = settings.explicitVisibility ?? !hardwareKeyboardAttached

        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.keyboardAttachmentChanged(true)
                }
            },
            center.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.keyboardAttachmentChanged(false)
                }
            },
        ]
    }

    deinit {
        let observers = keyboardObservers
        NotificationCenter.default.removeObserver(observers)
    }

    /// Chrome toggle: flips visibility and persists the explicit choice —
    /// sticky across launches and keyboard attach/detach.
    func toggle() {
        isVisible.toggle()
        settings.setExplicitVisibility(isVisible)
    }

    /// Drops the persisted choice and returns to the heuristic default
    /// (the UITest driver uses this for launch determinism).
    func clearExplicitChoice() {
        settings.clearExplicitChoice()
        isVisible = !hardwareKeyboardAttached
    }

    /// Dismiss-control action (the host gates the tap on an input surface
    /// actually being on screen — GCKeyboard is a false positive on the
    /// simulator, where the Mac keyboard bridges as a controller while
    /// the software keyboard remains the visible input surface).
    /// Dismissal from either surface lands in `.hidden`.
    func hideSoftwareKeyboard() {
        guard inputMode != .hidden else { return }
        inputMode = .hidden
    }

    /// Terminal-tap re-enable: from `.hidden` back to the system keyboard.
    /// The tapping surface refocuses its own terminal; every other
    /// surface clears its blocker through the SwiftUI update this flip
    /// triggers.
    func showSoftwareKeyboard() {
        guard inputMode == .hidden else { return }
        inputMode = .keyboard
    }

    /// The function-keys toggle (strip button and scene menu item, same
    /// route): `.keyboard` ↔ `.functionKeys`, and from `.hidden` straight
    /// to `.functionKeys` — the panel IS the input surface while active,
    /// so any sticky hide clears. Deterministic in both directions and
    /// independent of the toolbar strip's visibility: the scene-menu item
    /// is always reachable, so the hunk-16-era trap (a strip-only toggle)
    /// cannot recur.
    func toggleFunctionKeys() {
        inputMode = inputMode == .functionKeys ? .keyboard : .functionKeys
    }

    private func keyboardAttachmentChanged(_ attached: Bool) {
        hardwareKeyboardAttached = attached
        if settings.explicitVisibility == nil {
            isVisible = !attached
        }
        if attached, inputMode == .hidden {
            // A hardware keyboard taking over ends the sticky dismissal:
            // the software keyboard is no longer the input source, and
            // the blocker would keep the terminal from focusing for
            // hardware keys. The function-key panel deliberately survives
            // (see `inputMode`): it is an explicit user mode and hardware
            // keys deliver in parallel.
            inputMode = .keyboard
        }
    }
}

/// Stacks the terminal view above SwiftTerm's `TerminalAccessory` as a
/// LAYOUT PARTICIPANT: the terminal shrinks by the strip's height when the
/// toolbar is shown, so its bottom row is never covered. UIKit's
/// `inputAccessoryView` dock is NOT used — on iPad with a hardware keyboard
/// it overlays the terminal's bottom rows.
final class TerminalToolbarHostView: UIView {
    let terminalView: TerminalContainerView
    let accessoryView: TerminalAccessory
    private let accessoryHeight: CGFloat

    private(set) var showsAccessory = false

    /// Sticky keyboard-dismiss control: trailing slot in the strip row,
    /// shown only while the strip is shown AND a scene wired the dismiss
    /// action (session scenes and the herdr embed; previews keep the
    /// strip exactly as before this feature). While the keyboard is
    /// sticky-hidden the same slot shows the paste control instead —
    /// see ``stripPasteButton``.
    private let keyboardDismissButton = UIButton(type: .system)
    /// Keyboard-free paste affordance (K3): the strip's trailing app slot
    /// swaps to this Paste control while the software keyboard is
    /// sticky-hidden — the state where the system text-edit menu is the
    /// only other touch path. Tapping routes through the terminal's
    /// existing `paste(_:)` semantics: multi-line pastes go through the
    /// scene's paste-preview confirmation, everything else through
    /// SwiftTerm's direct (bracketed) delivery. Only surfaces that wire
    /// the dismiss action (sessions, herdr embed) ever go sticky-hidden,
    /// so the control is naturally scoped to those.
    private let stripPasteButton = UIButton(type: .system)
    private let stripControlWidth: CGFloat = 44

    /// Dismiss-control action, wired by session scenes: flips the
    /// app-global toolbar model's guarded hide. Nil keeps the control
    /// hidden.
    var onDismissKeyboard: (() -> Void)? {
        didSet { refreshStripControls() }
    }
    /// Function-keys toggle action, wired by session scenes (the strip's
    /// function-keys button and the scene-menu item route here). Nil (the
    /// DEBUG preview) leaves the strip button inert.
    var onToggleFunctionKeys: (() -> Void)?
    /// A tap in the terminal area while the software keyboard is
    /// sticky-hidden, wired by session scenes: flips the app-global
    /// model back to shown. This host then re-enables and refocuses its
    /// own terminal immediately (see ``terminalTapped(_:)``).
    var onTerminalTap: (() -> Void)?
    /// Mirror of the app-global input-surface mode applied to this
    /// surface's terminal through the fork's runtime toggles.
    private(set) var inputMode: TerminalInputMode = .keyboard
    /// Debounce state for the tap-to-re-enable: a plain single tap
    /// re-enables after the double-tap window passes; a second tap inside
    /// the window cancels it (selection gesture).
    private var pendingKeyboardReenable: DispatchWorkItem?
    private var multiTapSuppressedUntil = Date.distantPast
    /// Whether a software keyboard is currently on this screen — the
    /// dismiss control's gate. Tracked from keyboard frame notifications
    /// (the same signal K2's layout work consumes): GCKeyboard cannot be
    /// used here because the simulator bridges the Mac keyboard as a
    /// controller while the software keyboard stays the visible input
    /// surface.
    private var softwareKeyboardVisible = false
    /// Keyboard-frame layout tracking (K2): when enabled, the keyboard's
    /// end frame (screen coordinates) from the active
    /// keyboardWillChangeFrame notification, nil while no keyboard is on
    /// screen. Session scenes and the herdr embed enable tracking; the
    /// embedded client reflows its grid through the winsize path the
    /// resize triggers.
    private var keyboardScreenFrame: CGRect?
    /// Dismissal-squeeze recovery, part 1 — the layout floor. SwiftUI
    /// transiently squeezes this host by the keyboard inset when the
    /// keyboard dismisses (despite the scene's
    /// `.ignoresSafeArea(.keyboard)` opt-out, which holds only while the
    /// keyboard is up), and the correcting layout pass is unreliable —
    /// the host can stay squeezed until the next focus event. While an
    /// input surface (keyboard or function-key panel) constrains the
    /// layout, the host sits at its full-height position; that bottom
    /// edge in WINDOW coordinates is captured here on every constrained
    /// pass, and while nothing constrains the layout the terminal's
    /// bottom stays pinned to it — so the squeeze cannot shrink the
    /// terminal and the later recovery cannot resize it (an in-flight
    /// selection survives; upstream processSizeChange clears selections
    /// on grid resizes). Window-anchored so content changes above the
    /// host self-correct, and only honored while it still fits the
    /// current window (a real window resize wins).
    private var constrainedBottomInWindow: CGFloat?
    /// Dismissal-squeeze recovery, part 2 — the recovery probe. A
    /// dismissal that leaves the host squeezed schedules this focus
    /// probe: re-focusing the terminal through the sticky-hide blocker
    /// posts a keyboard-frame notification that refreshes SwiftUI's
    /// stale keyboard inset and restores the host's true frame,
    /// recovering touch delivery below the squeezed SwiftUI slot. The
    /// floor makes this focus-triggered recovery safe for an in-flight
    /// selection gesture (no terminal resize on either side of it).
    /// Main-thread-confined like the keyboard observer below.
    nonisolated(unsafe) private var squeezeRecoveryProbe: DispatchWorkItem?
    /// The smallest shrink the floor is honored for: the dismissal
    /// squeeze is the full keyboard inset (200+ pt); margin changes
    /// (≤ 20 pt) and banner-driven shrinks (which move the host's origin,
    /// self-correcting the window-anchored floor) stay below it.
    private let squeezeFloorMargin: CGFloat = 60
    /// Session scenes and the herdr embed opt in to keyboard-frame layout
    /// tracking.
    var tracksKeyboardFrame = false
    nonisolated(unsafe) private var keyboardFrameObserver: NSObjectProtocol?

    deinit {
        if let keyboardFrameObserver {
            NotificationCenter.default.removeObserver(keyboardFrameObserver)
        }
        squeezeRecoveryProbe?.cancel()
    }

    init(terminalView: TerminalContainerView) {
        self.terminalView = terminalView
        // Matches SwiftTerm's own docked accessory heights
        // (setupAccessoryView: 36 on phone, 48 otherwise).
        // Accessibility note: the strip's buttons live in the VENDORED
        // SwiftTerm TerminalAccessory (UIKit), so the 36pt phone strip and
        // its sub-44pt keys are upstream's layout, not app code — raising
        // the height here would leave the vendored button layout
        // vertically misaligned. The 44pt minimum is therefore met only by
        // the chrome toggle that shows/hides this strip; the strip keys
        // stay at the vendored size until a SwiftTerm fork hunk (recorded
        // in Vendor/SwiftTerm/BICTERM-PATCH.md) takes ownership of them.
        accessoryHeight = UIDevice.current.userInterfaceIdiom == .phone ? 36 : 48
        accessoryView = TerminalAccessory(
            frame: CGRect(x: 0, y: 0, width: 320, height: accessoryHeight),
            inputViewStyle: .keyboard,
            container: terminalView
        )
        super.init(frame: .zero)

        accessoryView.isHidden = true
        accessoryView.accessibilityIdentifier = "terminal-accessory"
        addSubview(terminalView)
        addSubview(accessoryView)
        #if DEBUG
        keyboardUILog.notice("app-hosted TerminalAccessory strip created (TerminalToolbarHostView)")
        #endif

        // Fork hunk 17: the strip's function-keys button routes through
        // the terminal's hook; the mode state stays app-owned (this host
        // forwards to the scene-wired closure). The hook is a plain
        // closure (fork-side typing constraint) invoked from a UIControl
        // action — always the main thread, hence the assumeIsolated hop.
        terminalView.onToggleAlternateKeyboard = { [weak self] in
            MainActor.assumeIsolated {
                self?.onToggleFunctionKeys?()
            }
        }

        keyboardDismissButton.setImage(
            UIImage(
                systemName: "keyboard.chevron.compact.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            ),
            for: .normal
        )
        keyboardDismissButton.accessibilityIdentifier = "terminal-keyboard-dismiss"
        keyboardDismissButton.accessibilityLabel = "Dismiss keyboard"
        keyboardDismissButton.addTarget(self, action: #selector(keyboardDismissTapped(_:)), for: .touchUpInside)
        keyboardDismissButton.isHidden = true
        addSubview(keyboardDismissButton)

        stripPasteButton.setImage(
            UIImage(
                systemName: "doc.on.clipboard",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            ),
            for: .normal
        )
        stripPasteButton.accessibilityIdentifier = "terminal-strip-paste"
        stripPasteButton.accessibilityLabel = "Paste"
        stripPasteButton.addTarget(self, action: #selector(stripPasteTapped(_:)), for: .touchUpInside)
        stripPasteButton.isHidden = true
        addSubview(stripPasteButton)

        // Re-enable recognizer: with the sticky hide active, UIKit's own
        // focus path (SwiftTerm's singleTap becomeFirstResponder) shows
        // only the invisible blocker — this recognizer is the app's
        // explicit re-enable. cancelsTouchesInView keeps SwiftTerm's own
        // tap handling (selection, links, context menu) untouched, and
        // the delegate's simultaneous recognition keeps this tap from
        // CANCELLING SwiftTerm's double-tap (default exclusivity would
        // tear down word selection); the handler debounces multi-taps so
        // a selection gesture never re-enables the keyboard.
        let terminalTap = UITapGestureRecognizer(target: self, action: #selector(terminalTapped(_:)))
        terminalTap.cancelsTouchesInView = false
        terminalTap.delegate = self
        terminalView.addGestureRecognizer(terminalTap)

        keyboardFrameObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
            MainActor.assumeIsolated {
                guard let self else { return }
                // Hidden keyboards animate to a frame fully below the
                // screen; a visible one intersects it.
                guard let screen = self.window?.screen else { return }
                let visible = endFrame.intersects(screen.bounds)
                #if DEBUG
                keyboardUILog.notice(
                    "keyboard frame visible=\(visible) endFrame=\(endFrame.debugDescription, privacy: .public)"
                )
                #endif
                self.softwareKeyboardVisible = visible
                self.applyKeyboardFrame(visible ? endFrame : nil, duration: duration, curve: curve)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setAccessoryVisible(_ visible: Bool) {
        guard visible != showsAccessory else { return }
        showsAccessory = visible
        accessoryView.isHidden = !visible
        refreshStripControls()
        setNeedsLayout()
    }

    /// Applies the app-global input-surface mode to this surface's
    /// terminal: `.hidden` installs the hunk-15 blocker and resigns;
    /// `.functionKeys` installs the panel through the fork's hunk-17 API
    /// (which focuses the terminal when needed, so summoning is
    /// deterministic); `.keyboard` returns the system keyboard. The
    /// blocker application runs FIRST so the two toggles compose in every
    /// transition order. Refocusing on re-enable is the tapping surface's
    /// job (``terminalTapped(_:)``) — a propagated show must not steal
    /// focus from the window the user is actually tapping in.
    func setInputMode(_ mode: TerminalInputMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        terminalView.setSoftwareKeyboardInstalled(mode != .hidden)
        terminalView.setAlternateKeyboardActive(mode == .functionKeys)
        refreshStripControls()
        setNeedsLayout()
    }

    private var keyboardDismissControlVisible: Bool {
        showsAccessory && onDismissKeyboard != nil && inputMode != .hidden
    }

    private var stripPasteControlVisible: Bool {
        showsAccessory && inputMode == .hidden
    }

    /// Keyboard-frame tracking (K2): stores the new end frame and reflows
    /// the layout alongside the keyboard's own animation, so the terminal
    /// never sits under the keyboard mid-transition either. The grid
    /// resize (SwiftTerm layoutSubviews → sizeChanged → pty winsize) fires
    /// from the layout pass this triggers.
    private func applyKeyboardFrame(_ screenFrame: CGRect?, duration: Double, curve: UInt) {
        guard tracksKeyboardFrame, screenFrame != keyboardScreenFrame else { return }
        keyboardScreenFrame = screenFrame
        scheduleSqueezeRecoveryProbe(dismissed: screenFrame == nil)
        // The keyboard's animation curve arrives as a private
        // UIView.AnimationCurve raw value; AnimationOptions encodes curve
        // bits at << 16.
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, options]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// Dismissal-squeeze recovery, part 2: a dismissal schedules a focus
    /// probe for shortly after the keyboard's slide-away animation; any
    /// other keyboard-frame change (the keyboard or panel coming back)
    /// cancels it. See ``squeezeRecoveryProbe`` for the mechanism.
    private func scheduleSqueezeRecoveryProbe(dismissed: Bool) {
        squeezeRecoveryProbe?.cancel()
        squeezeRecoveryProbe = nil
        guard dismissed else { return }
        let probe = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only the sticky hide leaves the terminal focusable without
            // a keyboard; only the foreground scene's squeeze is worth
            // recovering (a backgrounded scene re-layouts on activation).
            guard self.inputMode == .hidden,
                  self.window?.isKeyWindow == true,
                  self.dismissalRecoveryBottom() > self.bounds.maxY
            else { return }
            self.terminalView.becomeFirstResponder()
        }
        squeezeRecoveryProbe = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: probe)
    }

    /// The Y coordinate the terminal + strip stack must end at: the
    /// smallest of the host's own bottom (or the dismissal-recovery floor
    /// standing in for it), the tracked keyboard's top edge, and — while
    /// the function-key panel is this surface's input view — the panel's
    /// deterministic top edge (R1 layout parity: the app knows the
    /// panel's height; keyboard-frame notifications do not fire for
    /// custom input views, so the panel inset is computed, not observed).
    private func keyboardLayoutBottom() -> CGFloat {
        var bottom = dismissalRecoveryBottom()
        if let keyboardScreenFrame, let window {
            let frameInHost = convert(window.convert(keyboardScreenFrame, from: nil), from: window)
            if frameInHost.minY < bottom {
                bottom = max(bounds.minY, frameInHost.minY)
            }
        }
        if let panelScreenFrame = functionKeyPanelScreenFrame, let window {
            let frameInHost = convert(window.convert(panelScreenFrame, from: nil), from: window)
            if frameInHost.minY < bottom {
                bottom = max(bounds.minY, frameInHost.minY)
            }
        }
        return bottom
    }

    /// Dismissal-squeeze recovery, part 1: the host's own bottom edge for
    /// layout — the raw bounds bottom, or the captured full-height bottom
    /// while SwiftUI's dismissal squeeze has the host shrunk below it.
    /// See ``constrainedBottomInWindow`` for the full contract.
    private func dismissalRecoveryBottom() -> CGFloat {
        guard let floorBottom = constrainedBottomInWindow, let window else { return bounds.maxY }
        let floorInHost = floorBottom - convert(CGPoint.zero, to: window).y
        guard floorInHost > bounds.maxY + squeezeFloorMargin,
              floorBottom <= window.bounds.maxY + 1
        else { return bounds.maxY }
        return floorInHost
    }

    /// The function-key panel's screen frame while it is on screen for
    /// THIS surface (mode `.functionKeys` and the terminal first
    /// responder — the fork's docked input view). Nil otherwise.
    private var functionKeyPanelScreenFrame: CGRect? {
        guard inputMode == .functionKeys,
              terminalView.isFirstResponder,
              let window
        else { return nil }
        let screen = window.screen
        let height = terminalView.alternateKeyboardPanelHeight
        return CGRect(
            x: screen.bounds.minX,
            y: screen.bounds.maxY - height,
            width: screen.bounds.width,
            height: height
        )
    }

    private func refreshStripControls() {
        keyboardDismissButton.isHidden = !keyboardDismissControlVisible
        stripPasteButton.isHidden = !stripPasteControlVisible
        setNeedsLayout()
    }

    @objc private func keyboardDismissTapped(_ sender: UIButton) {
        // Gate: with no input surface on screen there is nothing to
        // dismiss, and the sticky-hide resignation would silently drop
        // hardware-key delivery to a focused terminal. The function-key
        // panel counts as the dismissable input surface while it is up
        // (the keyboard-frame tracker may not have caught the custom
        // input view's frame yet, so the mode gates too).
        guard softwareKeyboardVisible || inputMode == .functionKeys else { return }
        onDismissKeyboard?()
    }

    @objc private func stripPasteTapped(_ sender: UIButton) {
        // The terminal's paste(_:) override owns the policy: multi-line
        // pastes route through the scene's preview confirmation, every
        // other case through SwiftTerm's direct (bracketed) delivery.
        terminalView.paste(nil)
    }

    @objc private func terminalTapped(_ gesture: UITapGestureRecognizer) {
        guard inputMode == .hidden else { return }
        if let pending = pendingKeyboardReenable {
            // A second tap inside the double-tap window: a selection
            // gesture — cancel the pending re-enable and ignore the rest
            // of this tap burst.
            pending.cancel()
            pendingKeyboardReenable = nil
            multiTapSuppressedUntil = Date().addingTimeInterval(0.6)
            return
        }
        guard Date() >= multiTapSuppressedUntil else { return }
        let reenable = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKeyboardReenable = nil
            guard self.inputMode == .hidden else { return }
            self.onTerminalTap?()
            // Re-enable THIS surface immediately — the model flip reaches
            // other surfaces through SwiftUI, but the tapped terminal must
            // not wait for it (and must focus even if it was not first
            // responder when the recognizer fired).
            self.setInputMode(.keyboard)
            self.terminalView.becomeFirstResponder()
        }
        pendingKeyboardReenable = reenable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reenable)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG
        // T2 defensive assertion: the app never uses UIKit's
        // inputAccessoryView dock (it overlays the terminal's bottom rows
        // when a hardware keyboard is attached) — the strip lives in THIS
        // host's layout, so the terminal's dock must stay nil at every
        // hosting site.
        assert(
            terminalView.inputAccessoryView == nil,
            "terminal inputAccessoryView must stay nil (app-hosted strip contract)"
        )
        #endif
        let strip = showsAccessory ? accessoryHeight : 0
        // One trailing app slot in the strip row: the dismiss control
        // while the keyboard is installed, the paste control while it is
        // sticky-hidden.
        let slot = (keyboardDismissControlVisible || stripPasteControlVisible) ? stripControlWidth : 0
        // The strip + keyboard insets stack: the terminal shrinks by the
        // strip AND the keyboard overlap, and the strip sits directly
        // above the keyboard's top edge (never under it).
        let layoutBottom = keyboardLayoutBottom()
        // Dismissal-squeeze recovery, part 1: while an input surface
        // constrains the layout the host sits at its full-height
        // position — capture that bottom edge (window coordinates) as
        // the floor the layout keeps when the dismissal squeeze later
        // shrinks the host's own bounds.
        if layoutBottom < bounds.maxY, let window {
            constrainedBottomInWindow = convert(bounds, to: window).maxY
        }
        // Frame assignments are guarded: TerminalAccessory rebuilds its
        // buttons from a `bounds` didSet, and the terminal recomputes its
        // grid in layoutSubviews — neither should churn on a no-op pass.
        let terminalFrame = CGRect(x: 0, y: 0, width: bounds.width, height: layoutBottom - strip)
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
        }
        if showsAccessory {
            let accessoryFrame = CGRect(x: 0, y: layoutBottom - strip, width: bounds.width - slot, height: strip)
            if accessoryView.frame != accessoryFrame {
                accessoryView.frame = accessoryFrame
            }
            if slot > 0 {
                let slotFrame = CGRect(
                    x: bounds.width - slot,
                    y: layoutBottom - strip,
                    width: slot,
                    height: strip
                )
                if keyboardDismissControlVisible, keyboardDismissButton.frame != slotFrame {
                    keyboardDismissButton.frame = slotFrame
                }
                if stripPasteControlVisible, stripPasteButton.frame != slotFrame {
                    stripPasteButton.frame = slotFrame
                }
            }
        }
    }
}

extension TerminalToolbarHostView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The re-enable tap must never cancel SwiftTerm's own gesture
        // chain: default exclusivity would tear down a double-tap word
        // selection the moment this single-tap recognized. Recognizing
        // simultaneously and debouncing multi-taps in the handler keeps
        // both behaviors alive.
        true
    }
}
