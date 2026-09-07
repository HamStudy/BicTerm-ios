import SwiftTerm
import SwiftUI
import UIKit

#if DEBUG
/// UITEST-only focus shim for the terminal preview (phase-1 T12 follow-up).
///
/// Role: the preview's terminal container must keep first responder through
/// the SSH-echo paint storm so `app.typeKey` / `app.typeText` keep landing on
/// SwiftTerm's real input responders. This controller owns a main-tick
/// `DispatchSourceTimer` that re-asserts the container as first responder
/// whenever UIKit demotes it (the loop starts in `viewDidAppear`), hosts a
/// hidden forwarding `UITextField` as a fallback text-input responder
/// (plain-text `insertText` passthrough only — encoded keys still travel the
/// presses pipeline), and publishes the discovered container for the other
/// DEBUG seams via ``activeContainer``.
///
/// Focus target note: earlier iterations made the interposer view itself
/// first responder. That was refuted in `.sisyphus/journal/t12/debug-journal.md`:
/// with a non-text-input responder holding focus, `app.typeText` fails with
/// "Neither element nor any descendant has keyboard focus". Re-asserting the
/// container keeps the proven-green CJK path intact.
final class TestKeyInterposerController: UIViewController {
    /// The live preview terminal, discovered by walking the scene windows.
    /// Consumed by `TestHardwareKeyInjector`; never set in Release.
    private(set) static var activeContainer: TerminalContainerView?

    private weak var container: TerminalContainerView?
    private weak var textField: TestKeyInterposerTextField?
    private var focusTimer: DispatchSourceTimer?
    private var discoveryAttempts = 0

    override func loadView() {
        let root = UIView(frame: .zero)
        root.isUserInteractionEnabled = false
        root.isAccessibilityElement = false

        // Hidden, zero-frame, default (nil) input view. It is never made
        // first responder today, so no software keyboard is ever installed
        // for it; the forwarding closures keep it a valid fallback if UIKit
        // focus semantics change across runtime releases.
        let field = TestKeyInterposerTextField(frame: .zero)
        field.isHidden = true
        root.addSubview(field)
        textField = field
        view = root
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        discoveryAttempts = 0
        discoverContainer()
        startFocusLoop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        focusTimer?.cancel()
        focusTimer = nil
        if let container, TestKeyInterposerController.activeContainer === container {
            TestKeyInterposerController.activeContainer = nil
        }
    }

    /// The representable and this controller mount in the same SwiftUI pass,
    /// but ordering is not guaranteed; retry on the next runloop tick for a
    /// bounded window before giving up (the seams degrade to no-ops).
    private func discoverContainer() {
        if let found = Self.findContainerInSceneWindows() {
            attach(to: found)
            return
        }
        discoveryAttempts += 1
        guard discoveryAttempts < 40, view.window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.discoverContainer()
        }
    }

    private func attach(to container: TerminalContainerView) {
        self.container = container
        TestKeyInterposerController.activeContainer = container
        textField?.onInsertText = { [weak container] text in
            container?.insertText(text)
        }
        textField?.onDeleteBackward = { [weak container] in
            container?.deleteBackward()
        }
        if !container.isFirstResponder {
            container.becomeFirstResponder()
        }
    }

    private func startFocusLoop() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let container = self?.container, container.window != nil,
                  !container.isFirstResponder else { return }
            container.becomeFirstResponder()
        }
        focusTimer = timer
        timer.resume()
    }

    private static func findContainerInSceneWindows() -> TerminalContainerView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let found = findContainer(in: window) {
                    return found
                }
            }
        }
        return nil
    }

    private static func findContainer(in view: UIView) -> TerminalContainerView? {
        if let container = view as? TerminalContainerView {
            return container
        }
        for subview in view.subviews {
            if let found = findContainer(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Fallback plain-text responder. Forwarding keeps bytes on SwiftTerm's real
/// `UIKeyInput` implementation — no byte is hand-crafted here.
final class TestKeyInterposerTextField: UITextField {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override func insertText(_ text: String) {
        if let onInsertText {
            onInsertText(text)
        } else {
            super.insertText(text)
        }
    }

    override func deleteBackward() {
        if let onDeleteBackward {
            onDeleteBackward()
        } else {
            super.deleteBackward()
        }
    }
}

/// SwiftUI host: the preview screen places this in a `.background` overlay.
struct InterposerControllerHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TestKeyInterposerController {
        TestKeyInterposerController()
    }

    func updateUIViewController(_ uiViewController: TestKeyInterposerController, context: Context) {}
}
#endif
