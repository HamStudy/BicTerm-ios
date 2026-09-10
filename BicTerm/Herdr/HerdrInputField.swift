import HerdrClientCore
import SwiftUI
import UIKit

/// Invisible full-size first responder behind the workspace canvas: hardware
/// presses arrive via `pressesBegan`, soft-keyboard and IME-committed text
/// via `insertText`, composition edits stay local until commit. Events are
/// already semantic (`HerdrKeyInput` / committed strings); routing, gating,
/// and ordering live in ``HerdrSessionModel``.
final class HerdrInputField: UITextField {
    var onText: ((String) -> Void)?
    var onKey: ((HerdrKeyInput) -> Void)?
    var onNavigate: ((HerdrFocusDirection) -> Void)?

    private var repeatTimer: Timer?
    private var keyWindowObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        borderStyle = .none
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        accessibilityIdentifier = "herdr-input-field"
        // didMoveToWindow runs before the window is key, and
        // becomeFirstResponder only sticks on a key window — re-assert on
        // the transition or the workspace opens without keyboard input.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                self.becomeFirstResponder()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
    }

    /// Always true so the keyboard never drops into its no-text behaviors
    /// (the field's own storage is a scratchpad; real content lives in the
    /// committed surface).
    override var hasText: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            #if DEBUG
            TestHardwareKeyInjector.herdrInputField = self
            #endif
        } else {
            stopRepeating()
            #if DEBUG
            // A recreated host registers itself before the old instance
            // tears down; only the live instance may clear the registration.
            if TestHardwareKeyInjector.herdrInputField === self {
                TestHardwareKeyInjector.herdrInputField = nil
            }
            #endif
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // During IME composition the input system owns every key.
        guard markedTextRange == nil else {
            stopRepeating()
            if event != nil { super.pressesBegan(presses, with: event) }
            return
        }
        var unhandled: [UIPress] = []
        for press in presses {
            guard let key = press.key else { continue }
            switch HerdrKeyMapper.resolve(HerdrKeyStroke(key: key)) {
            case .event(let input):
                onKey?(input)
                startRepeating(input)
            case .navigate(let direction):
                onNavigate?(direction)
            case .textFallthrough, .ignored:
                unhandled.append(press)
            }
        }
        // Synthetic test presses carry no event; UIKit's default forwarding
        // traps on a nil UIPressesEvent, so only real events go to super.
        if !unhandled.isEmpty, event != nil {
            super.pressesBegan(Set(unhandled), with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating()
        if event != nil { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating()
        if event != nil { super.pressesCancelled(presses, with: event) }
    }

    /// IME-committed text only — composition arrives via setMarkedText and
    /// is never forwarded. super runs first so UIKit's marking/selection
    /// bookkeeping stays consistent; the payload goes to the model.
    override func insertText(_ text: String) {
        super.insertText(text)
        if text == "\n" || text == "\r" {
            onKey?(HerdrKeyInput(code: .enter))
        } else {
            onText?(text)
        }
    }

    override func deleteBackward() {
        // During composition delete edits the pending text, not the pane.
        guard markedTextRange == nil else {
            super.deleteBackward()
            return
        }
        onKey?(HerdrKeyInput(code: .backspace))
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        stopRepeating()
        return super.resignFirstResponder()
    }

    /// UIKit never repeats hardware presses; mirror the T3 terminal's
    /// 0.4s initial delay / 0.1s interval with explicit repeat events.
    private func startRepeating(_ key: HerdrKeyInput) {
        stopRepeating()
        var repeated = key
        repeated.kind = .repeat
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.4), interval: 0.1, repeats: true) { [weak self] _ in
            self?.onKey?(repeated)
        }
        RunLoop.current.add(timer, forMode: .default)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

extension HerdrInputField: UITextFieldDelegate {
    /// Soft-keyboard return arrives here instead of insertText.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onKey?(HerdrKeyInput(code: .enter))
        return false
    }
}

struct HerdrInputFieldHost: UIViewRepresentable {
    var onText: (String) -> Void
    var onKey: (HerdrKeyInput) -> Void
    var onNavigate: (HerdrFocusDirection) -> Void

    func makeUIView(context: Context) -> HerdrInputField {
        let field = HerdrInputField(frame: .zero)
        field.onText = onText
        field.onKey = onKey
        field.onNavigate = onNavigate
        return field
    }

    func updateUIView(_ field: HerdrInputField, context: Context) {
        field.onText = onText
        field.onKey = onKey
        field.onNavigate = onNavigate
    }
}
