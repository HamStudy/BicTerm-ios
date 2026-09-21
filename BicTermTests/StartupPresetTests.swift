import BicTermCore
import XCTest
@testable import BicTerm

/// T5 startup-command presets: the preset↔string mapping helper, whitespace
/// normalization, draft dirty-tracking, and herdr gating. Editor UI only —
/// the typed `Connection.startupCommand` field and the registry's
/// command-plus-Return replay stay untouched.
final class StartupPresetTests: XCTestCase {

    // MARK: Preset ↔ string mapping

    func testPresetCommandTexts() {
        XCTAssertEqual(StartupCommandPreset.shell.commandText, "")
        XCTAssertEqual(StartupCommandPreset.tmux.commandText, "tmux new-session -A -s main")
        XCTAssertEqual(StartupCommandPreset.screen.commandText, "screen -xRR main")
        XCTAssertNil(StartupCommandPreset.custom.commandText, "Custom preserves whatever the user typed")
    }

    func testPresetForExactCommandStrings() {
        XCTAssertEqual(StartupCommandPreset.preset(for: ""), .shell)
        XCTAssertEqual(StartupCommandPreset.preset(for: "tmux new-session -A -s main"), .tmux)
        XCTAssertEqual(StartupCommandPreset.preset(for: "screen -xRR main"), .screen)
        XCTAssertEqual(StartupCommandPreset.preset(for: "emacs -nw"), .custom)
        XCTAssertEqual(StartupCommandPreset.preset(for: "tmux attach"), .custom,
                       "a non-preset tmux invocation is Custom, not tmux")
    }

    func testPresetForWhitespaceOnlyTextIsShell() {
        for blank in [" ", "   ", " \t\n "] {
            XCTAssertEqual(StartupCommandPreset.preset(for: blank), .shell,
                           "whitespace-only \(blank.debugDescription) displays as Shell")
        }
    }

    func testPresetForPaddedPresetTextMatchesAfterTrim() {
        XCTAssertEqual(StartupCommandPreset.preset(for: "  tmux new-session -A -s main\n"), .tmux)
        XCTAssertEqual(StartupCommandPreset.preset(for: "\tscreen -xRR main "), .screen)
    }

    func testPresetRoundTripsThroughCommandText() {
        for preset in StartupCommandPreset.allCases {
            guard let text = preset.commandText else {
                XCTAssertEqual(StartupCommandPreset.preset(for: "custom-command"), preset)
                continue
            }
            XCTAssertEqual(StartupCommandPreset.preset(for: text), preset)
        }
    }

    // MARK: Whitespace normalization at save

    func testWhitespaceOnlyCommandSavesAsNoCommand() throws {
        var draft = ConnectionDraft()
        draft.name = "Blank"
        draft.host = "example.com"
        draft.port = "22"
        draft.username = "user"
        draft.startupCommand = "   "
        XCTAssertEqual(StartupCommandPreset.preset(for: draft.startupCommand), .shell)
        XCTAssertNil(try draft.makeConnection().startupCommand,
                     "whitespace-only text must save as no command")
    }

    func testCustomTextSavesVerbatim() throws {
        var draft = ConnectionDraft()
        draft.name = "Custom"
        draft.host = "example.com"
        draft.port = "22"
        draft.username = "user"
        draft.startupCommand = "emacs -nw"
        XCTAssertEqual(StartupCommandPreset.preset(for: draft.startupCommand), .custom)
        XCTAssertEqual(try draft.makeConnection().startupCommand, "emacs -nw")
    }

    // MARK: Dirty tracking (discard confirmation comes free via Equatable)

    func testStartupCommandEditFlipsDraftDirtyState() {
        var draft = ConnectionDraft()
        let original = draft

        draft.startupCommand = StartupCommandPreset.tmuxCommand
        XCTAssertNotEqual(draft, original, "picking a preset must make the draft dirty")

        draft.startupCommand = ""
        XCTAssertEqual(draft, original, "reverting to Shell must read clean again")
    }

    // MARK: Herdr gating hides the rows without clearing the stored command

    func testHerdrGatingRetainsStoredCommandWithoutClearing() throws {
        let connection = try Connection(
            name: "Gated", type: .ssh, host: "example.com", port: 22, username: "user",
            protocolOptions: try ProtocolOptions([ProtocolOptions.herdrEnabledKey: .bool(true)]),
            startupCommand: StartupCommandPreset.tmuxCommand
        )
        var draft = ConnectionDraft(connection: connection, keyLabel: nil)
        XCTAssertTrue(draft.herdrEnabled, "herdr mode hides the startup rows")
        XCTAssertEqual(draft.startupCommand, StartupCommandPreset.tmuxCommand,
                       "hiding must not clear the stored command")

        draft.herdrEnabled = false
        XCTAssertEqual(draft.startupCommand, StartupCommandPreset.tmuxCommand,
                       "revealing the rows must not touch the value either")
        draft.herdrEnabled = true

        let saved = try draft.makeConnection()
        XCTAssertTrue(saved.herdrEnabled)
        XCTAssertEqual(saved.startupCommand, StartupCommandPreset.tmuxCommand,
                       "a herdr-hidden startup command must persist across the save")
    }
}
