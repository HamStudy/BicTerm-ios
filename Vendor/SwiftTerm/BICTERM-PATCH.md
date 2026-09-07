# BicTerm patch — SwiftTerm terminal view

Vendored fork of [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
tag **v1.20.0** (commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`), MIT
(LICENSE preserved verbatim).

- **Vendored at**: `Vendor/SwiftTerm/` (rsync from the upstream checkout at the
  pin; `.git`, `Package.resolved`, and `.build` excluded).
- **App consumer**: `BicTerm` only (the app target). `BicTermCore` does not
  link SwiftTerm.
- **Referenced from**: `project.yml` `packages.SwiftTerm.path = ./Vendor/SwiftTerm`.

## Why this fork exists

`XCUIApplication.typeKey(_:modifierFlags:)` synthesizes a hardware key event via
the XCTest HID manager but does NOT synthesize a paired
`pressesEnded(_:with:)`. Two consequences against unmodified SwiftTerm 1.20.0:

1. SwiftTerm's `pressesBegan` schedules a repeating
   `Timer(interval: 0.1, repeats: true)` on `RunLoop.main` for hardware key
   auto-repeat, invalidated only from `pressesEnded`. Without a paired release
   the Timer fires forever, the echoed bytes keep the main run loop busy, and
   XCTest's `_XCTPerformOnMainRunLoop` hits its 60-second idle timeout on every
   interaction. Cancelling that timer unconditionally would fix the test but
   break production hold-to-repeat — the fix must be an app-side DEBUG seam,
   which needs access to the timer.
2. When a text-input responder with the `.causesPageTurn` accessibility trait
   and a `nil` input view becomes first responder under XCUI, UIKit materializes
   `UIRemoteKeyboardWindow` / `UITextEffectsWindow`; the resulting
   accessibility-tree churn independently pins the same 60-second idle wait.
   Suppressing that machinery must be opt-in so production input behavior is
   byte-identical to upstream.

Real hardware keys deliver paired `pressesBegan` + `pressesEnded`, so
production is unaffected by either.

## Hunks

Every deviation carries an inline `// BICTERM-PATCH hunk N:` marker in
`Sources/SwiftTerm/iOS/iOSTerminalView.swift`. All hunks are production-inert:
hunks 1/2 are access widenings that change nothing until a subclass uses them;
hunks 3/4/5 engage only when `installsSoftwareKeyboard == false`, which only
the app's DEBUG UI-test preview sets (production keeps the `true` default).

### Hunk 1 — `var keyRepeat: Timer?` → `public var keyRepeat: Timer?`

```diff
-    var keyRepeat: Timer?
+    // BICTERM-PATCH hunk 1: expose the existing repeat timer …
+    public var keyRepeat: Timer?
```

Exposes the auto-repeat Timer so the app's DEBUG preview subclass
(`TerminalContainerView.pressesBegan` override) can invalidate it directly
after `super.pressesBegan` when XCTest omits the release event. Timer
creation, the 0.4 s initial delay, the 0.1 s interval, and invalidation in
`pressesEnded` are unchanged.

### Hunk 2 — `pressesEnded` access: `public override` → `open override`

```diff
-    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
+    // BICTERM-PATCH hunk 2: widen to `open` …
+    open override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
```

Allows a cross-module subclass to override the release half of the physical-key
lifecycle, and lets the DEBUG key injector invoke it directly to mirror real
hardware after a synthesized press. The method body is byte-identical to
upstream. (`public` methods are callable but not overridable cross-module;
`open` is the minimal widening that allows both.)

### Hunk 3 — new `public var installsSoftwareKeyboard: Bool = true`

```diff
+    // BICTERM-PATCH hunk 3: opt-out flag for software-keyboard installation. …
+    public var installsSoftwareKeyboard: Bool = true
```

The public opt-out flag consulted by hunks 4 and 5. Default `true` preserves
upstream behavior for every consumer that does not flip it.

### Hunk 4 — hidden blocker input view (in `didMoveToWindow`)

```diff
     open override func didMoveToWindow() {
         super.didMoveToWindow()
+        // BICTERM-PATCH hunk 4: with the software keyboard opted out, …
+        if !installsSoftwareKeyboard {
+            let blocker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
+            blocker.isHidden = true
+            _inputView = blocker
+            accessibilityTraits = accessibilityTraits.subtracting(.causesPageTurn)
+        }
         updateTextBlinkLifecycle()
```

With the flag off, a hidden 1×1 `UIView` becomes `inputView`. UIKit treats a
responder with a non-nil input view as already keyboard-served and never
creates the system keyboard scene for it. The blocker is a fresh instance per
terminal view (no shared-reparenting hazard across iPad scenes).

### Hunk 5 — `.causesPageTurn` gated on the flag (`completeInit` + `didMoveToWindow` follow-up)

```diff
     private func completeInit()
     {
         isAccessibilityElement = true
-        accessibilityTraits.formUnion([.staticText, .causesPageTurn])
+        // BICTERM-PATCH hunk 5: advertise .causesPageTurn only while the
+        // software keyboard is installed. …
+        accessibilityTraits.formUnion([.staticText])
+        if installsSoftwareKeyboard {
+            accessibilityTraits.formUnion(.causesPageTurn)
+        }
```

UIKit consults `.causesPageTurn` when deciding whether to spin up the remote
keyboard / text-effects windows for a first responder. `completeInit` runs
inside the designated initializers — before any embedder can flip the flag —
so the `didMoveToWindow` block in hunk 4 also subtracts the trait
("hunk 5 follow-up" in that comment), where the DEBUG preview's `false` value
is already in effect.

## What is NOT changed

- No key routing, encoding, timer creation, or timer invalidation logic. The
  Timer is still created in `pressesBegan` and invalidated in `pressesEnded`
  exactly as upstream intends; production physical keyboards keep the 0.4 s
  initial delay and 0.1 s repeat interval because `pressesEnded` always
  arrives for real hardware.
- `pressesBegan` was already `open override` upstream.
- `progressReportTimer`, `textBlinkTimer`, the Kitty keyboard protocol path,
  `optionAsMetaKey` handling, `queuePendingDisplay`, focus/`responder`
  lifecycle: all untouched.
- Hunks 4/5 do not engage in production: `installsSoftwareKeyboard` defaults
  to `true` and only the app's `-uitest-terminal-preview` DEBUG surface sets
  it to `false`.

## App-side consumers (DEBUG only, `#if DEBUG`)

- `BicTerm/Terminal/TerminalRepresentable.swift`
  (`TerminalContainerView.pressesBegan`): `super.pressesBegan` then direct
  `keyRepeat?.invalidate(); keyRepeat = nil`. Single delivery — it does NOT
  chase `pressesEnded` (chase-calling would double-invalidate and double-send
  Kitty release events). Gated on the `-uitest-terminal-preview` launch
  argument, absent from Release compilation.
- `BicTerm/Terminal/TestKeyInterposerController.swift`: DEBUG terminal-preview
  focus shim — hosts a hidden forwarding `UITextField` (plain-text
  `insertText` passthrough for `app.typeText`), runs a main-tick
  `DispatchSourceTimer` that re-asserts first responder on the terminal
  container when a paint storm demotes it, and discovers/exposes the live
  `TerminalContainerView` for test seams.
- `BicTerm/Terminal/TestHardwareKeyInjector.swift`: `--uitest-hwkeys` launch
  argument — the DEBUG app synthesizes real `UIKey`/`UIPress` subclass
  instances and delivers them through the same
  `pressesBegan` → SwiftTerm encoder → SSH transport path (plus a paired
  `pressesEnded`, exercising hunk 2's widened access). Used because
  `XCUIApplication.typeKey` never delivers Escape/Home/End/PageUp/PageDown and
  drops the first Control modifier on the simulator (runtime discrimination in
  `.sisyphus/journal/t12/debug-journal.md`). Compiled out of Release.

## Rebase instructions

```sh
git fetch --tags https://github.com/migueldeicaza/SwiftTerm
git checkout v1.20.0  # or the upstream tag to rebase against
# Re-apply the 5 inline hunks (search for "BICTERM-PATCH hunk"):
#   hunk 1  keyRepeat -> public                      (presses section)
#   hunk 2  pressesEnded -> open                     (presses section)
#   hunk 3  installsSoftwareKeyboard property        (next to hunk 1)
#   hunk 4  blocker inputView in didMoveToWindow     (gated on !flag)
#   hunk 5  .causesPageTurn gated on flag            (completeInit + didMoveToWindow)
```

If XCTest's `typeKey` ever synthesizes a paired `pressesEnded` and the missing
special keys, hunks 1–2 and the DEBUG consumers could be reverted; hunks 3–5
remain harmless even then (default-off).
