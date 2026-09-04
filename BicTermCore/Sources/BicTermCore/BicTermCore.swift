// BicTermCore — platform-independent core module.
//
// ARCHITECTURAL INVARIANT: this module must NEVER import SwiftUI or UIKit.
// Enforcement: scripts/check-isolation.sh (runs in CI / pre-commit).
// All SSH, transport, session, and key logic (tasks T7–T11) lives here.

/// Namespace for the core module. Real API lands in later tasks.
public enum BicTermCore {
    public static let moduleName = "BicTermCore"
}
