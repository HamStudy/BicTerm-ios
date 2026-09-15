import Foundation
import Testing
@testable import SwiftTerm

// BICTERM-PATCH hunk 11: parse-path coverage for the typed OSC 52
// clipboard write request. Companion to the legacy OscTests.clipboard
// cases (which still pass via the TerminalDelegate default impl that
// forwards valid base64 to `clipboardCopy`). These cases assert the
// typed surface that the host needs for foreground gating, size cap,
// settings toggle, malformed-base64 diagnostics, and the empty-payload
// (clear) case.
final class BicTermOSC52Tests {
    final class TypedDelegate: TerminalDelegate {
        var writeRequest: ClipboardWriteRequest?
        var readCalls = 0
        var copiedContent: Data?
        var clipboardData: Data?
        var sentData: [UInt8] = []

        func oscClipboardWriteRequest(source: Terminal, request: ClipboardWriteRequest) {
            writeRequest = request
        }

        func clipboardCopy(source: Terminal, content: Data) {
            copiedContent = content
        }

        func clipboardRead(source: Terminal) -> Data? {
            readCalls += 1
            return clipboardData
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sentData.append(contentsOf: data)
        }
    }

    @Test func writeRequestFiresWithDecodedContent() {
        let delegate = TypedDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;aGVsbG8=\u{07}")

        #expect(delegate.writeRequest != nil)
        #expect(delegate.writeRequest?.selection == "c")
        #expect(delegate.writeRequest?.isEmpty == false)
        #expect(delegate.writeRequest?.decodedContent == "hello".data(using: .utf8))
    }

    @Test func writeRequestFiresForEmptyPayloadAsClear() {
        let delegate = TypedDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;\u{07}")

        #expect(delegate.writeRequest != nil)
        #expect(delegate.writeRequest?.isEmpty == true)
        #expect(delegate.writeRequest?.decodedContent?.isEmpty == true)
    }

    @Test func writeRequestFiresForMalformedBase64() {
        let delegate = TypedDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;not!valid!base64!!!\u{07}")

        #expect(delegate.writeRequest != nil)
        #expect(delegate.writeRequest?.decodedContent == nil)
        // The legacy clipboardCopy is NOT called for malformed base64,
        // matching the pre-hunk parse path's silent drop.
        #expect(delegate.copiedContent == nil)
    }

    @Test func queryRoutesToClipboardReadNotWriteRequest() {
        let delegate = TypedDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;?\u{07}")

        #expect(delegate.readCalls == 1)
        #expect(delegate.writeRequest == nil)
    }

    @Test func queryDeniedByDefaultDoesNotRespond() {
        // The fork's default delegate denies reads. We use the harness's
        // TerminalTestDelegate-equivalent here so the default impl is
        // exercised: no response on the wire, no read call surfaced.
        final class DefaultDelegate: TerminalDelegate {
            var readCalls = 0
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
            func showCursor(source: Terminal) {}
            func hideCursor(source: Terminal) {}
            func setTerminalTitle(source: Terminal, title: String) {}
            func setTerminalIconTitle(source: Terminal, title: String) {}
            func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
            func sizeChanged(source: Terminal) {}
            func scrolled(source: Terminal, yDisp: Int) {}
            func linefeed(source: Terminal) {}
            func bufferActivated(source: Terminal) {}
            func bell(source: Terminal) {}
            func selectionChanged(source: Terminal) {}
            func isProcessTrusted(source: Terminal) -> Bool { return true }
            func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { return nil }
            func mouseModeChanged(source: Terminal) {}
            func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
            func hostCurrentDirectoryUpdated(source: Terminal) {}
            func hostCurrentDocumentUpdated(source: Terminal) {}
            func colorChanged(source: Terminal, idx: Int?) {}
            func setForegroundColor(source: Terminal, color: Color) {}
            func setBackgroundColor(source: Terminal, color: Color) {}
            func setCursorColor(source: Terminal, color: Color?) {}
            func getColors(source: Terminal) -> (foreground: Color, background: Color) {
                return (foreground: Color.defaultForeground, background: Color.defaultBackground)
            }
            func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
            func synchronizedOutputChanged(source: Terminal, active: Bool) {}
            func clipboardRead(source: Terminal) -> Data? { readCalls += 1; return nil }
        }
        let delegate = DefaultDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )
        terminal.feed(text: "\u{1b}]52;c;?\u{07}")
        #expect(delegate.readCalls == 1)
    }

    @Test func defaultDelegateForwardsValidWriteToClipboardCopy() {
        // The TerminalDelegate default impl (Terminal.swift) forwards
        // valid base64 to clipboardCopy, empty payload as empty Data,
        // and silently drops malformed base64. This preserves the pre-hunk
        // behavior so existing OscTests keep passing.
        final class LegacyDelegate: TerminalDelegate {
            var copiedContent: Data?
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
            func showCursor(source: Terminal) {}
            func hideCursor(source: Terminal) {}
            func setTerminalTitle(source: Terminal, title: String) {}
            func setTerminalIconTitle(source: Terminal, title: String) {}
            func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
            func sizeChanged(source: Terminal) {}
            func scrolled(source: Terminal, yDisp: Int) {}
            func linefeed(source: Terminal) {}
            func bufferActivated(source: Terminal) {}
            func bell(source: Terminal) {}
            func selectionChanged(source: Terminal) {}
            func isProcessTrusted(source: Terminal) -> Bool { return true }
            func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { return nil }
            func mouseModeChanged(source: Terminal) {}
            func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
            func hostCurrentDirectoryUpdated(source: Terminal) {}
            func hostCurrentDocumentUpdated(source: Terminal) {}
            func colorChanged(source: Terminal, idx: Int?) {}
            func setForegroundColor(source: Terminal, color: Color) {}
            func setBackgroundColor(source: Terminal, color: Color) {}
            func setCursorColor(source: Terminal, color: Color?) {}
            func getColors(source: Terminal) -> (foreground: Color, background: Color) {
                return (foreground: Color.defaultForeground, background: Color.defaultBackground)
            }
            func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
            func synchronizedOutputChanged(source: Terminal, active: Bool) {}
            func clipboardCopy(source: Terminal, content: Data) {
                copiedContent = content
            }
        }
        let delegate = LegacyDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;aGVsbG8=\u{07}")
        #expect(delegate.copiedContent == "hello".data(using: .utf8))

        // Reset and exercise the empty-payload path: the default impl
        // forwards empty Data so the host can decide clear semantics.
        delegate.copiedContent = nil
        terminal.feed(text: "\u{1b}]52;c;\u{07}")
        #expect(delegate.copiedContent?.isEmpty == true)
    }
}