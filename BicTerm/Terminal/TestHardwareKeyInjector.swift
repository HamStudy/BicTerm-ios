import Foundation
import SwiftTerm
import UIKit

#if DEBUG
/// UITEST-only hardware-key injector (phase-1 T12 fallback, bounded).
///
/// `XCUIApplication.typeKey` on the simulator never delivers Escape, Home,
/// End, PageUp, or PageDown to `pressesBegan`, and drops the Control modifier
/// from the first Ctrl-letter press (runtime discrimination recorded in
/// `.sisyphus/journal/t12/debug-journal.md` across iPhone/iPad and iOS
/// 26.3.1/26.5). With the `--uitest-hwkeys <spec>` launch argument, the DEBUG
/// app synthesizes the equivalent presses itself — real `UIKey`/`UIPress`
/// subclass instances delivered through the container's actual
/// `pressesBegan`/`pressesEnded` overrides, so the bytes traverse SwiftTerm's
/// own encoder (`KittyKeyboardEncoder` legacy path), the delegate, and the
/// SSH transport exactly like a physical keyboard. No byte is hand-crafted.
///
/// Spec grammar: comma-separated tokens. `ctrl+<letter>`, `meta+<letter>`,
/// and bare key names (`esc`, `tab`, `arrows`, `home`, `end`, `pageup`,
/// `pagedown`). `await:decckm` suspends injection until the remote has set
/// application-cursor mode (DECCKM, ESC[?1h), required by SwiftTerm semantics:
/// unmodified PageUp/PageDown are local scrollback while
/// `terminal.applicationCursor == false`.
    /// spec grammar — comma tokens: `ctrl+<letter>`, `meta+<letter>`, bare names
    /// (`esc`, `tab`, arrows, `home`, `end`, `pageup`, `pagedown`),
    /// `nav+<arrow>` (ctrl+shift pane navigation), `text:<string>` (one
    /// `insertText` commit per grapheme into the herdr input field — XCUI
    /// `typeText` no-ops against the replay scene even with the field as
    /// key-window responder and a live RTI session, the same simulator
    /// delivery gap as `typeKey`), `await:decckm` to suspend until the
    /// remote's DECCKM (ESC[?1h) lands in the tail, and
    /// `await:echo:<needle>` to suspend until the herdr input echo contains
    /// the needle (tap-first ordering). Text payloads run to the next comma
    /// and are whitespace-trimmed. Main-actor confined: it calls UIKit
    /// responder methods.
    @MainActor
    final class TestHardwareKeyInjector {
        struct SyntheticKeystroke: Equatable {
            let code: UIKeyboardHIDUsage
            let modifiers: UIKeyModifierFlags
            let characters: String
            let charactersIgnoringModifiers: String
        }

        enum Step: Equatable {
            case key(SyntheticKeystroke)
            case awaitTail(String)
        }

    /// The ready signal as PRINTED by the `-uitest-command` shell probe —
    /// including the trailing CRLF (bytes are matched at the UTF-8 level via
    /// `byteContents`: `String.contains` respects grapheme boundaries and
    /// `\r\n` is one `Character`, so any marker ending inside that cluster
    /// would never match). The echoed command text (`printf __GO__\n; …`)
    /// must not trigger injection while zsh is still setting up the
    /// foreground job — only the printed line ends in CRLF.
    private static let goMarker = "__GO__\r\n"
    /// DECCKM set — observed as raw bytes in the preview tail.
    private static let decckmSetMarker = "\u{1B}[?1h"
    /// Delay between injected keys: long enough for each press+release pair
    /// to be encoded and delivered before the next one begins (the paired
    /// release must preempt the 0.4 s repeat delay, which 50 ms honors).
    private static let interKeyDelay: DispatchTimeInterval = .milliseconds(50)

    private let steps: [Step]
    private var started = false
    private var pendingResume: (marker: String, index: Int)?
    private var missingContainerRetries = 0
    /// Bumped on cancel() so in-flight asyncAfter continuations no-op.
    private var generation = 0

    init?(spec: String?) {
        guard let spec, !spec.isEmpty, let parsed = Self.parse(spec), !parsed.isEmpty else {
            if let spec, !spec.isEmpty {
                NSLog("TestHardwareKeyInjector: refusing unparseable --uitest-hwkeys spec \(spec.debugDescription)")
            }
            return nil
        }
        steps = parsed
        NSLog("TestHardwareKeyInjector: armed with %d steps", parsed.count)
    }

    func cancel() {
        generation += 1
        pendingResume = nil
    }

    /// Fed with the preview's decoded tail on every remote chunk
    /// (main-actor). Kicks the sequence on the ready marker and resumes after
    /// each awaited in-band marker.
    /// Tail feed from `TerminalPreviewController.handle` (every remote chunk,
    /// main actor). Matching is BYTE-level: the printed markers sit next to
    /// CRLF, and `String.contains` respects grapheme Cluster boundaries —
    /// `\r\n` is one `Character`, so a marker ending in `\n` can never match
    /// the real tail. `utf8.firstRange(of:)` is immune to that.
    func note(tail: String) {
        guard let pending = pendingResume else {
            guard !started, Self.byteContents(tail, Self.goMarker) else { return }
            started = true
            NSLog("TestHardwareKeyInjector: go-marker observed, starting injection")
            runSteps(from: 0, generation: generation)
            return
        }
        guard Self.byteContents(tail, pending.marker) else { return }
        pendingResume = nil
        // The tail observes remote bytes when `handle` runs, BEFORE the
        // representable's async feed task has parsed them into SwiftTerm's
        // terminal state (DECCKM flips `applicationCursor`, which decides
        // page-key encoding). Settle for 250 ms so the parse lands first.
        NSLog("TestHardwareKeyInjector: marker %@ observed, settling before step %d", pending.marker.debugDescription, pending.index)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.runSteps(from: pending.index, generation: self?.generation ?? -1)
        }
    }



    private static func byteContents(_ tail: String, _ marker: String) -> Bool {
        tail.utf8.firstRange(of: marker.utf8) != nil
    }

    private func runSteps(from index: Int, generation: Int) {
        guard self.generation == generation, index < steps.count else {
            if index >= steps.count {
                NSLog("TestHardwareKeyInjector: sequence complete (%d steps)", steps.count)
            }
            return
        }
        switch steps[index] {
        case .awaitTail(let marker):
            pendingResume = (marker, index + 1)
            NSLog("TestHardwareKeyInjector: awaiting marker %@", marker.debugDescription)
        case .key(let keystroke):
            guard deliver(keystroke) else {
                retryStep(from: index, generation: generation)
                return
            }
            missingContainerRetries = 0
            if index == 0 {
                NSLog("TestHardwareKeyInjector: first key delivered (code %d)", keystroke.code.rawValue)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.interKeyDelay) { [weak self] in
                self?.runSteps(from: index + 1, generation: generation)
            }
        }
    }

    private func retryStep(from index: Int, generation: Int) {
        missingContainerRetries += 1
        guard missingContainerRetries < 50 else {
            NSLog("TestHardwareKeyInjector: no live terminal container after 5 s; steps from %d dropped", index)
            return
        }
        if missingContainerRetries == 1 {
            NSLog("TestHardwareKeyInjector: container not yet discoverable; retrying step %d", index)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.runSteps(from: index, generation: generation)
        }
    }

    func startNow() {
        guard !started else { return }
        started = true
        NSLog("TestHardwareKeyInjector: starting injection")
        runSteps(from: 0, generation: generation)
    }

    /// The paired release event mirrors real hardware; XCTest itself never
    /// sends it, and SwiftTerm's encoder depends on it for repeat-timer
    /// invariants.
    private func deliver(_ keystroke: SyntheticKeystroke) -> Bool {
        let key = TestKeySyntheticUIKey(
            code: keystroke.code,
            modifiers: keystroke.modifiers,
            characters: keystroke.characters,
            charactersIgnoringModifiers: keystroke.charactersIgnoringModifiers
        )
        let press = TestKeySyntheticUIPress(key: key)
        if let container = TestKeyInterposerController.activeContainer,
           container.window != nil {
            container.pressesBegan([press], with: nil)
            container.pressesEnded([press], with: nil)
            return true
        }
        return false
    }

    private static func parse(_ spec: String) -> [Step]? {
        var steps: [Step] = []
        for rawToken in spec.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            switch token {
            case "esc":
                steps.append(.key(SyntheticKeystroke(code: .keyboardEscape, modifiers: [], characters: "\u{1B}", charactersIgnoringModifiers: "")))
            case "tab":
                steps.append(.key(SyntheticKeystroke(code: .keyboardTab, modifiers: [], characters: "\t", charactersIgnoringModifiers: "\t")))
            case "home":
                steps.append(.key(SyntheticKeystroke(code: .keyboardHome, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "end":
                steps.append(.key(SyntheticKeystroke(code: .keyboardEnd, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "pageup":
                steps.append(.key(SyntheticKeystroke(code: .keyboardPageUp, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "pagedown":
                steps.append(.key(SyntheticKeystroke(code: .keyboardPageDown, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "up":
                steps.append(.key(SyntheticKeystroke(code: .keyboardUpArrow, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "down":
                steps.append(.key(SyntheticKeystroke(code: .keyboardDownArrow, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "left":
                steps.append(.key(SyntheticKeystroke(code: .keyboardLeftArrow, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "right":
                steps.append(.key(SyntheticKeystroke(code: .keyboardRightArrow, modifiers: [], characters: "", charactersIgnoringModifiers: "")))
            case "await:decckm":
                steps.append(.awaitTail(decckmSetMarker))
            default:
                guard let keystroke = parseModifiedLetter(token) else { return nil }
                steps.append(.key(keystroke))
            }
        }
        return steps
    }

    /// `ctrl+<ascii letter>` / `meta+<ascii letter>` with realistic
    /// `characters` payloads (e.g. Ctrl-C carries U+0003, matching what UIKit
    /// reports for a physical chord; the encoder reads
    /// `charactersIgnoringModifiers` for both paths).
    private static func parseModifiedLetter(_ token: String) -> SyntheticKeystroke? {
        enum Chord { case control, alternate }
        let chord: Chord
        let letterToken: String
        if token.hasPrefix("ctrl+") {
            chord = .control
            letterToken = String(token.dropFirst(5))
        } else if token.hasPrefix("meta+") {
            chord = .alternate
            letterToken = String(token.dropFirst(5))
        } else {
            return nil
        }
        guard letterToken.count == 1, let letter = letterToken.lowercased().first,
              letter.isLetter, let scalar = letter.unicodeScalars.first,
              scalar.isASCII else { return nil }
        let code: UIKeyboardHIDUsage
        switch letter {
        case "b": code = .keyboardB
        case "c": code = .keyboardC
        case "d": code = .keyboardD
        default: return nil
        }
        switch chord {
        case .control:
            let controlScalar = UnicodeScalar(UInt8(scalar.value & 0x1F))
            return SyntheticKeystroke(
                code: code,
                modifiers: [.control],
                characters: String(controlScalar),
                charactersIgnoringModifiers: String(letter)
            )
        case .alternate:
            return SyntheticKeystroke(
                code: code,
                modifiers: [.alternate],
                characters: String(letter),
                charactersIgnoringModifiers: String(letter)
            )
        }
    }
}

/// Real `UIKey` stand-in: SwiftTerm's `pressesBegan` reads only
/// `keyCode`/`modifierFlags`/`characters`/`charactersIgnoringModifiers`.
final class TestKeySyntheticUIKey: UIKey {
    private let syntheticCode: UIKeyboardHIDUsage
    private let syntheticModifiers: UIKeyModifierFlags
    private let syntheticCharacters: String
    private let syntheticCharactersIgnoringModifiers: String

    init(code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, characters: String, charactersIgnoringModifiers: String) {
        syntheticCode = code
        syntheticModifiers = modifiers
        syntheticCharacters = characters
        syntheticCharactersIgnoringModifiers = charactersIgnoringModifiers
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("synthetic keys are not archivable")
    }

    override var keyCode: UIKeyboardHIDUsage { syntheticCode }
    override var modifierFlags: UIKeyModifierFlags { syntheticModifiers }
    override var characters: String { syntheticCharacters }
    override var charactersIgnoringModifiers: String { syntheticCharactersIgnoringModifiers }
}

final class TestKeySyntheticUIPress: UIPress {
    private let syntheticKey: UIKey

    init(key: UIKey) {
        syntheticKey = key
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("synthetic presses are not archivable")
    }

    override var key: UIKey? { syntheticKey }
}
#endif
