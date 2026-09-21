import UIKit
import XCTest
@testable import BicTerm

/// T12: every SSH password field advertises `.password` for Passwords
/// AutoFill. The helper is the single source of truth; the three call sites
/// (PasswordPromptView, ConnectionEditorView, HopEditorView) consume it
/// directly at compile time, so no view introspection is needed here.
final class PasswordAutofillTests: XCTestCase {
    func testHelperExposesPasswordContentType() {
        XCTAssertEqual(SSHPasswordContentType.contentType, .password)
    }

    func testContentTypeIsTheSystemPasswordType() {
        XCTAssertEqual(SSHPasswordContentType.contentType.rawValue, "password")
    }
}
