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

    private func keyboardAttachmentChanged(_ attached: Bool) {
        hardwareKeyboardAttached = attached
        if settings.explicitVisibility == nil {
            isVisible = !attached
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setAccessoryVisible(_ visible: Bool) {
        guard visible != showsAccessory else { return }
        showsAccessory = visible
        accessoryView.isHidden = !visible
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let strip = showsAccessory ? accessoryHeight : 0
        // Frame assignments are guarded: TerminalAccessory rebuilds its
        // buttons from a `bounds` didSet, and the terminal recomputes its
        // grid in layoutSubviews — neither should churn on a no-op pass.
        let terminalFrame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - strip)
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
        }
        if showsAccessory {
            let accessoryFrame = CGRect(x: 0, y: bounds.height - strip, width: bounds.width, height: strip)
            if accessoryView.frame != accessoryFrame {
                accessoryView.frame = accessoryFrame
            }
        }
    }
}
