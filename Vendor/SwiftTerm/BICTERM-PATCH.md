# SwiftTerm (BicTerm fork) — local patch note

- **Upstream**: https://github.com/migueldeicaza/SwiftTerm
- **Upstream pin**: tag `v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`
- **License**: MIT (preserved verbatim at `Vendor/SwiftTerm/LICENSE`)
- **Vendored at**: `Vendor/SwiftTerm/` (rsync from `.build-artifacts/SourcePackages/checkouts/SwiftTerm` at the upstream pin; `.git`, `Package.resolved`, and `.build` excluded)
- **App consumer**: `BicTerm` only (the app target). `BicTermCore` does not link SwiftTerm.
- **Original remote pin removed from**: `project.yml` (replaced with `path: ./Vendor/SwiftTerm`).

## Why a fork

`XCUIApplication.typeKey(_:modifierFlags:)` synthesizes a hardware key event via the XCTest HID manager but does NOT synthesize a paired `pressesEnded(_:with:)`. SwiftTerm 1.20.0's `iOSTerminalView.pressesBegan` schedules a repeating `Timer(interval: 0.1, repeats: true)` on `RunLoop.main` for hardware key auto-repeat (see lines 2910–2975 and 3130–3140 of the vendored file). That Timer only invalidates from `pressesEnded`. Without a paired `pressesEnded`, the Timer keeps firing every 100 ms — each fire sends bytes through the SSH transport, the loopback sshd echoes them back, `cat -v` re-feeds SwiftTerm, `queuePendingDisplay` re-schedules a 16.67 ms `DispatchQueue.main.asyncAfter` — the main run loop never reaches idle. `XCUIApplication`'s `_XCTPerformOnMainRunLoop` polls every 250 ms and hits its 60-second timeout per interaction.

Real hardware keys deliver paired `pressesBegan` + `pressesEnded` events via UIKit. SwiftTerm intentionally uses the interval between them for physical-key repeat, so BicTerm must not cancel this timer in production.

An app-only DEBUG workaround needs access to the existing timer because:
- `keyRepeat` is `internal` (not accessible cross-module).

The fork widens that property's access only. It does not change SwiftTerm's key routing, timer creation, timer invalidation, input view, accessibility traits, or responder lifecycle.

## Patch (one access change in `Sources/SwiftTerm/iOS/iOSTerminalView.swift`)

### `var keyRepeat: Timer?` → `public var keyRepeat: Timer?`

```diff
-    var keyRepeat: Timer?
+    // BICTERM-PATCH: expose the existing repeat timer so the DEBUG UI-test
+    // preview can cancel it after XCTest omits a matching pressesEnded event.
+    // Timer creation and physical-key lifecycle remain unchanged here.
+    public var keyRepeat: Timer?
```

Why: exposes the timer so the DEBUG preview subclass can cancel it after SwiftTerm's encoder returns. Release never accesses it from BicTerm.

## What is NOT changed

- No SwiftTerm logic was edited. The only source change is the `keyRepeat` access modifier.
- No Timer lifecycle changed inside SwiftTerm. The Timer is still created in `pressesBegan` and invalidated in `pressesEnded` exactly as upstream intends. The app's DEBUG preview cancels the exposed timer directly after synthesized events where XCTest doesn't follow up.
- `pressesBegan` was already `open override` in upstream.
- The Timer's `RunLoop.main.add(...)` registration, the 0.4 s initial delay, the 0.1 s repeat interval, the Kitty keyboard protocol path, the optionAsMetaKey handling, the `dispatchPrecondition(condition: .onQueue(.main))` checks, and the `dismantleUIView` / `updateUiClosed` cleanup are all unchanged.
- All other Timer-related state (`progressReportTimer`, `textBlinkTimer`) is untouched.

## What the app-side change is

`BicTerm/Terminal/TerminalRepresentable.swift` (`TerminalContainerView.pressesBegan`) contains a DEBUG-only override:

```swift
override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    guard ProcessInfo.processInfo.arguments.contains("-uitest-terminal-preview") else { return }
    keyRepeat?.invalidate()
    keyRepeat = nil
}
```

This is the only consumer of the fork's widened access. There is no separate responder view, no interposer, and no hand-crafted byte path. Bytes still flow through SwiftTerm's own encoders and the existing `delegate.send(source:data:)` → `controller.send(_:)` → `SSHSessionTransport.send(_:)` chain.

`TerminalContainerView` remains the first responder and text-input responder. The override is absent from Release compilation, so physical hardware retains SwiftTerm's 0.4-second initial repeat delay and 0.1-second repeat interval until UIKit delivers `pressesEnded`.

## Rebase instructions

```sh
git fetch --tags https://github.com/migueldeicaza/SwiftTerm
git checkout v1.20.0  # or the upstream tag to rebase against
# Re-apply the single inline access change (search for "BICTERM-PATCH";
# if upstream moved the line, change only `var keyRepeat` to `public`).
```

If XCTest fixes `typeKey` to synthesize a paired `pressesEnded`, this access change and the app's DEBUG override can both be reverted.
