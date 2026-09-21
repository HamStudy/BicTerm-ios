import UIKit

/// SSH password fields advertise Passwords AutoFill semantics (`.password`).
/// They previously used the one-time-code content type to keep the system
/// password-vault save flow out of BicTerm's own Keychain persistence;
/// `.password` keeps secure entry while letting AutoFill recognize the field
/// as a password entry.
enum SSHPasswordContentType {
    /// The text content type applied to every SSH password field.
    static let contentType: UITextContentType = .password
}
