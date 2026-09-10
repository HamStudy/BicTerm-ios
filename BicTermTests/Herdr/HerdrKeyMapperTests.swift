import HerdrClientCore
import UIKit
import XCTest

@testable import BicTerm

/// T17 key mapper matrix: pure stroke → resolution mapping, no FFI. Mirrors
/// the T3 terminal contract — command chords stay local, ctrl+shift+arrows
/// navigate panes, functional keys and ctrl/alt chords become key events,
/// everything else falls through to UIKit text input.
final class HerdrKeyMapperTests: XCTestCase {
    private func stroke(
        _ keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) -> HerdrKeyStroke {
        HerdrKeyStroke(
            keyCode: keyCode,
            modifierFlags: modifiers,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    func testModifierBitsMatchTheCrosstermWireMask() {
        XCTAssertEqual(HerdrKeyMapper.modifierBits([]), 0)
        XCTAssertEqual(HerdrKeyMapper.modifierBits(.shift), 1)
        XCTAssertEqual(HerdrKeyMapper.modifierBits(.control), 2)
        XCTAssertEqual(HerdrKeyMapper.modifierBits(.alternate), 4)
        XCTAssertEqual(HerdrKeyMapper.modifierBits(.command), 8)
        XCTAssertEqual(HerdrKeyMapper.modifierBits([.control, .shift]), 3)
        XCTAssertEqual(HerdrKeyMapper.modifierBits([.shift, .control, .alternate, .command]), 15)
    }

    func testPlainAndShiftedCharactersFallThroughToTextInput() {
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardA, characters: "a", charactersIgnoringModifiers: "a")),
            .textFallthrough
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardA, modifiers: .shift, characters: "A", charactersIgnoringModifiers: "a"
            )),
            .textFallthrough,
            "shift only changes the committed text, not the routing"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardA)),
            .ignored,
            "a press with no characters at all (dead key) produces nothing"
        )
    }

    func testCommandChordsStayLocal() {
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardC, modifiers: .command, characters: "c", charactersIgnoringModifiers: "c")),
            .ignored
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardLeftArrow, modifiers: [.command, .shift], charactersIgnoringModifiers: ""
            )),
            .ignored,
            "command wins over the pane-navigation chord"
        )
    }

    func testControlShiftArrowsNavigatePanesInsteadOfReachingTheFFI() {
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardUpArrow, modifiers: [.control, .shift])),
            .navigate(.up)
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardDownArrow, modifiers: [.control, .shift])),
            .navigate(.down)
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardLeftArrow, modifiers: [.control, .shift])),
            .navigate(.left)
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardRightArrow, modifiers: [.control, .shift])),
            .navigate(.right)
        )
    }

    func testFunctionalKeysBecomeKeyEventsWithTheirModifierMask() {
        let cases: [(UIKeyboardHIDUsage, HerdrKeyCode)] = [
            (.keyboardReturnOrEnter, .enter),
            (.keyboardDeleteOrBackspace, .backspace),
            (.keyboardDeleteForward, .delete),
            (.keyboardLeftArrow, .left),
            (.keyboardRightArrow, .right),
            (.keyboardUpArrow, .up),
            (.keyboardDownArrow, .down),
            (.keyboardHome, .home),
            (.keyboardEnd, .end),
            (.keyboardPageUp, .pageUp),
            (.keyboardPageDown, .pageDown),
            (.keyboardEscape, .esc),
            (.keyboardTab, .tab),
        ]
        for (usage, code) in cases {
            XCTAssertEqual(
                HerdrKeyMapper.resolve(stroke(usage)),
                .event(HerdrKeyInput(code: code)),
                "\(usage) must map to \(code)"
            )
        }
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardTab, modifiers: .shift)),
            .event(HerdrKeyInput(code: .backTab, modifiers: 1)),
            "shift+tab is the backtab key event"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardHome, modifiers: .control)),
            .event(HerdrKeyInput(code: .home, modifiers: 2)),
            "functional keys keep their modifier mask for the wire"
        )
    }

    func testFunctionKeysMapByNumber() {
        XCTAssertEqual(HerdrKeyMapper.resolve(stroke(.keyboardF1)), .event(HerdrKeyInput(code: .function(1))))
        XCTAssertEqual(HerdrKeyMapper.resolve(stroke(.keyboardF5)), .event(HerdrKeyInput(code: .function(5))))
        XCTAssertEqual(HerdrKeyMapper.resolve(stroke(.keyboardF12)), .event(HerdrKeyInput(code: .function(12))))
    }

    func testControlAndAltCharactersBecomeModifiedCharEvents() {
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardC, modifiers: .control, characters: "\u{3}", charactersIgnoringModifiers: "c"
            )),
            .event(HerdrKeyInput(code: .char("c"), modifiers: 2)),
            "ctrl+c is the c char event with the ctrl mask"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardA, modifiers: [.control, .shift], characters: "\u{1}", charactersIgnoringModifiers: "a"
            )),
            .event(HerdrKeyInput(code: .char("a"), modifiers: 3)),
            "ctrl+shift+letter is a char event, not pane navigation (arrows only)"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardX, modifiers: .alternate, characters: "≈", charactersIgnoringModifiers: "x"
            )),
            .event(HerdrKeyInput(code: .char("x"), modifiers: 4)),
            "option-as-meta sends the unmodified key with the alt mask"
        )
    }

    func testChordedPressesWithoutAUsableScalarAreIgnored() {
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardC, modifiers: .control, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}"
            )),
            .ignored,
            "a control scalar below 0x20 in charactersIgnoringModifiers is not a char event"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(
                .keyboardC, modifiers: .control, charactersIgnoringModifiers: "xy"
            )),
            .ignored,
            "multi-scalar chords have no single codepoint to send"
        )
        XCTAssertEqual(
            HerdrKeyMapper.resolve(stroke(.keyboardC, modifiers: .control)),
            .ignored,
            "chord with no characters at all is not text and not a key event"
        )
    }
}
