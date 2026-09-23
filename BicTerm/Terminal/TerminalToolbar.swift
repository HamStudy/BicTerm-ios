import Foundation
import GameController
import SwiftTerm
import UIKit

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

    /// Sticky software-keyboard dismissal: true while the user dismissed
    /// the on-screen keyboard and it must stay down until an explicit
    /// re-enable (a terminal tap). Transient runtime state — never
    /// persisted; a fresh launch always starts with the keyboard
    /// installed.
    private(set) var keyboardHidden = false

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

    /// Dismiss-control action (the host gates the tap on the software
    /// keyboard actually being on screen — GCKeyboard is a false positive
    /// on the simulator, where the Mac keyboard bridges as a controller
    /// while the software keyboard remains the visible input surface).
    func hideSoftwareKeyboard() {
        guard !keyboardHidden else { return }
        keyboardHidden = true
    }

    /// Terminal-tap re-enable. The tapping surface refocuses its own
    /// terminal; every other surface clears its blocker through the
    /// SwiftUI update this flip triggers.
    func showSoftwareKeyboard() {
        guard keyboardHidden else { return }
        keyboardHidden = false
    }

    private func keyboardAttachmentChanged(_ attached: Bool) {
        hardwareKeyboardAttached = attached
        if settings.explicitVisibility == nil {
            isVisible = !attached
        }
        if attached, keyboardHidden {
            // A hardware keyboard taking over ends the sticky dismissal:
            // the software keyboard is no longer the input source, and
            // the blocker would keep the terminal from focusing for
            // hardware keys.
            keyboardHidden = false
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
    /// action (session scenes; the herdr embed and previews keep the strip
    /// exactly as before this feature). While the keyboard is
    /// sticky-hidden the same slot shows the paste control instead —
    /// see ``stripPasteButton``.
    private let keyboardDismissButton = UIButton(type: .system)
    /// Keyboard-free paste affordance (K3): the strip's trailing app slot
    /// swaps to this Paste control while the software keyboard is
    /// sticky-hidden — the state where the system text-edit menu is the
    /// only other touch path. Tapping routes through the terminal's
    /// existing `paste(_:)` semantics: multi-line pastes go through the
    /// scene's paste-preview confirmation, everything else through
    /// SwiftTerm's direct (bracketed) delivery. Only session surfaces
    /// ever go sticky-hidden (the herdr embed never calls
    /// setKeyboardHidden), so the control is naturally session-scoped.
    private let stripPasteButton = UIButton(type: .system)
    private let stripControlWidth: CGFloat = 44

    /// Dismiss-control action, wired by session scenes: flips the
    /// app-global toolbar model's guarded hide. Nil keeps the control
    /// hidden.
    var onDismissKeyboard: (() -> Void)? {
        didSet { refreshStripControls() }
    }
    /// A tap in the terminal area while the software keyboard is
    /// sticky-hidden, wired by session scenes: flips the app-global
    /// model back to shown. This host then re-enables and refocuses its
    /// own terminal immediately (see ``terminalTapped(_:)``).
    var onTerminalTap: (() -> Void)?
    /// Mirror of the app-global sticky-hide state applied to this
    /// surface's terminal through the fork's runtime toggle.
    private(set) var keyboardHidden = false
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
    /// screen. Session scenes enable tracking; the herdr embed keeps the
    /// keyboard as an overlay (the embedded client owns its grid).
    private var keyboardScreenFrame: CGRect?
    /// Session scenes opt in to keyboard-frame layout tracking.
    var tracksKeyboardFrame = false
    nonisolated(unsafe) private var keyboardFrameObserver: NSObjectProtocol?

    deinit {
        if let keyboardFrameObserver {
            NotificationCenter.default.removeObserver(keyboardFrameObserver)
        }
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

    /// Applies the app-global sticky-hide state to this surface's
    /// terminal (fork hunk 15 runtime toggle): hidden installs the
    /// blocker and resigns; shown clears the blocker. Refocusing on
    /// re-enable is the tapping surface's job (``terminalTapped(_:)``) —
    /// a propagated show must not steal focus from the window the user
    /// is actually tapping in.
    func setKeyboardHidden(_ hidden: Bool) {
        guard hidden != keyboardHidden else { return }
        keyboardHidden = hidden
        terminalView.setSoftwareKeyboardInstalled(!hidden)
        refreshStripControls()
    }

    private var keyboardDismissControlVisible: Bool {
        showsAccessory && onDismissKeyboard != nil && !keyboardHidden
    }

    private var stripPasteControlVisible: Bool {
        showsAccessory && keyboardHidden
    }

    /// Keyboard-frame tracking (K2): stores the new end frame and reflows
    /// the layout alongside the keyboard's own animation, so the terminal
    /// never sits under the keyboard mid-transition either. The grid
    /// resize (SwiftTerm layoutSubviews → sizeChanged → pty winsize) fires
    /// from the layout pass this triggers.
    private func applyKeyboardFrame(_ screenFrame: CGRect?, duration: Double, curve: UInt) {
        guard tracksKeyboardFrame, screenFrame != keyboardScreenFrame else { return }
        keyboardScreenFrame = screenFrame
        // The keyboard's animation curve arrives as a private
        // UIView.AnimationCurve raw value; AnimationOptions encodes curve
        // bits at << 16.
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, options]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// The Y coordinate the terminal + strip stack must end at: the
    /// keyboard's top edge in this view's coordinates when a keyboard
    /// overlaps this host, otherwise the host's own bottom.
    private func keyboardLayoutBottom() -> CGFloat {
        guard let keyboardScreenFrame, let window else { return bounds.maxY }
        let frameInHost = convert(window.convert(keyboardScreenFrame, from: nil), from: window)
        guard frameInHost.minY < bounds.maxY else { return bounds.maxY }
        return max(bounds.minY, frameInHost.minY)
    }

    private func refreshStripControls() {
        keyboardDismissButton.isHidden = !keyboardDismissControlVisible
        stripPasteButton.isHidden = !stripPasteControlVisible
        setNeedsLayout()
    }

    @objc private func keyboardDismissTapped(_ sender: UIButton) {
        // Gate: with no software keyboard on screen there is nothing to
        // dismiss, and the sticky-hide resignation would silently drop
        // hardware-key delivery to a focused terminal.
        guard softwareKeyboardVisible else { return }
        onDismissKeyboard?()
    }

    @objc private func stripPasteTapped(_ sender: UIButton) {
        // The terminal's paste(_:) override owns the policy: multi-line
        // pastes route through the scene's preview confirmation, every
        // other case through SwiftTerm's direct (bracketed) delivery.
        terminalView.paste(nil)
    }

    @objc private func terminalTapped(_ gesture: UITapGestureRecognizer) {
        guard keyboardHidden else { return }
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
            guard self.keyboardHidden else { return }
            self.onTerminalTap?()
            // Re-enable THIS surface immediately — the model flip reaches
            // other surfaces through SwiftUI, but the tapped terminal must
            // not wait for it (and must focus even if it was not first
            // responder when the recognizer fired).
            self.setKeyboardHidden(false)
            self.terminalView.becomeFirstResponder()
        }
        pendingKeyboardReenable = reenable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reenable)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let strip = showsAccessory ? accessoryHeight : 0
        // One trailing app slot in the strip row: the dismiss control
        // while the keyboard is installed, the paste control while it is
        // sticky-hidden.
        let slot = (keyboardDismissControlVisible || stripPasteControlVisible) ? stripControlWidth : 0
        // The strip + keyboard insets stack: the terminal shrinks by the
        // strip AND the keyboard overlap, and the strip sits directly
        // above the keyboard's top edge (never under it).
        let layoutBottom = keyboardLayoutBottom()
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
