import HerdrClientCore
import UIKit

/// UIKit-free snapshot of one hardware key press, so the mapping below stays
/// unit-testable (UIKey has no public initializer).
struct HerdrKeyStroke: Equatable, Sendable {
    var keyCode: UIKeyboardHIDUsage
    var modifierFlags: UIKeyModifierFlags
    var characters: String
    var charactersIgnoringModifiers: String

    @MainActor
    init(key: UIKey) {
        keyCode = key.keyCode
        modifierFlags = key.modifierFlags
        characters = key.characters
        charactersIgnoringModifiers = key.charactersIgnoringModifiers
    }

    init(
        keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }
}

/// What one hardware press resolves to before anything touches the FFI.
enum HerdrKeyResolution: Equatable, Sendable {
    case event(HerdrKeyInput)
    case navigate(HerdrFocusDirection)
    /// cmd+v: the keyboard paste gesture (doc §8.2). The chord itself is
    /// the user's explicit consent for the pasteboard read that follows.
    case paste
    case textFallthrough
    case ignored
}

/// Hardware key → semantic herdr input, mirroring the T3 terminal contract
/// (Vendor/SwiftTerm iOSTerminalView.pressesBegan): command chords stay
/// local, functional keys become key events with their modifier mask,
/// ctrl/alt-as-meta characters become modified char events, and everything
/// else falls through to UIKit text input (insertText → text commit).
enum HerdrKeyMapper {
    /// Same contract TerminalRepresentable hardcodes for the SSH terminal.
    static let optionAsMetaKey = true

    /// crossterm modifier mask carried by the herdr wire model.
    static func modifierBits(_ flags: UIKeyModifierFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.shift) { bits |= 1 }
        if flags.contains(.control) { bits |= 2 }
        if flags.contains(.alternate) { bits |= 4 }
        if flags.contains(.command) { bits |= 8 }
        return bits
    }

    static func resolve(_ stroke: HerdrKeyStroke) -> HerdrKeyResolution {
        if stroke.modifierFlags.contains(.command) {
            if stroke.keyCode == .keyboardV,
               stroke.charactersIgnoringModifiers.lowercased() == "v" {
                return .paste
            }
            return .ignored
        }
        if stroke.modifierFlags.contains([.control, .shift]),
           let direction = arrowDirection(stroke.keyCode) {
            return .navigate(direction)
        }
        if var code = functionalCode(stroke.keyCode) {
            if code == .tab, stroke.modifierFlags.contains(.shift) {
                code = .backTab
            }
            return .event(HerdrKeyInput(code: code, modifiers: modifierBits(stroke.modifierFlags)))
        }
        let chorded = stroke.modifierFlags.contains(.control)
            || (stroke.modifierFlags.contains(.alternate) && optionAsMetaKey)
        if chorded {
            guard let scalar = stroke.charactersIgnoringModifiers.unicodeScalars.only,
                  scalar.value >= 0x20 else { return .ignored }
            return .event(HerdrKeyInput(code: .char(scalar), modifiers: modifierBits(stroke.modifierFlags)))
        }
        return stroke.charactersIgnoringModifiers.isEmpty ? .ignored : .textFallthrough
    }

    private static func arrowDirection(_ code: UIKeyboardHIDUsage) -> HerdrFocusDirection? {
        switch code {
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        default: nil
        }
    }

    private static func functionalCode(_ code: UIKeyboardHIDUsage) -> HerdrKeyCode? {
        switch code {
        case .keyboardReturnOrEnter: .enter
        case .keyboardDeleteOrBackspace: .backspace
        case .keyboardDeleteForward: .delete
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardHome: .home
        case .keyboardEnd: .end
        case .keyboardPageUp: .pageUp
        case .keyboardPageDown: .pageDown
        case .keyboardEscape: .esc
        case .keyboardTab: .tab
        case .keyboardF1: .function(1)
        case .keyboardF2: .function(2)
        case .keyboardF3: .function(3)
        case .keyboardF4: .function(4)
        case .keyboardF5: .function(5)
        case .keyboardF6: .function(6)
        case .keyboardF7: .function(7)
        case .keyboardF8: .function(8)
        case .keyboardF9: .function(9)
        case .keyboardF10: .function(10)
        case .keyboardF11: .function(11)
        case .keyboardF12: .function(12)
        default: nil
        }
    }
}

private extension Collection where Element == Unicode.Scalar {
    var only: Unicode.Scalar? {
        count == 1 ? first : nil
    }
}
