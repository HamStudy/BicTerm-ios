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

The original five deviations carry inline `// BICTERM-PATCH hunk N:` markers in
`Sources/SwiftTerm/iOS/iOSTerminalView.swift`. Hunks 1-5 are production-inert:
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

## Mouse and selection repair (production, hunks 6-7)

### Hunk 6 — X10 event gates (`Terminal.swift`)

`MouseMode.sendButtonPress` now includes X10; `sendButtonRelease` excludes it.
Previously the two gates contradicted the documented X10 press-only behavior.
The existing `encodeButton`, `sendEvent`, and `sendMotion` encoders are reused,
including SGR 1006, legacy coordinates, modifier bits, and wheel buttons 64/65.

### Hunk 7 — UIKit routing (`iOS/iOSTerminalView.swift`)

- Replace the remote pan recognizer with a zero-delay long-press recognizer,
  so the remote receives the initial press before movement and a release on
  end/cancellation. Give it precedence over UIScrollView panning. Mode/Shift
  checks happen when recognition begins, so releasing Shift mid-gesture cannot
  turn a local drag into remote input or lose an already-required release.
- Install the recognizer once in `setupGestures` and keep it installed across
  mouse-mode changes; admission stays gated per gesture by
  `gestureRecognizerShouldBegin`. Tearing it down on a transient `?1000l`
  mid-gesture silently drops the pending release — the embedded herdr client
  re-emits disable+enable bursts in the same frame that answers a press, and
  every ripped-out recognizer took its in-flight touch's release with it.
- `mouseReportHit` uses bounded viewport-relative physical cells, rather than
  BiDi logical selection columns or buffer-absolute rows. Pixel coordinates are
  viewport-relative and one-based. Local selection retains buffer coordinates.
- `encodeFlags` forwards hardware Shift/Option/Control modifiers.
- `handleHover` forwards unpressed motion only for mode 1003.
- `setupPointerGestures`, `pointerSelection`, and `mouseWheel` add primary
  pointer drag selection and vertical discrete/continuous wheel or two-finger
  scrolling. The wheel recognizer can promote a held press into scrolling,
  cancelling/releasing the button first. Sub-cell deltas accumulate, and the
  terminal's native scroll recognizer remains available when reporting is off.
- Selection-handle drags take precedence over native scrolling. `linefeed`
  does not clear a local selection just because reporting is *allowed*.

The patch belongs in the fork because selection state, cell dimensions, gesture
installation, and mouse-mode callbacks are internal to SwiftTerm. No public
selection API or parallel mouse encoder was added. The app simply removes its
empty `TerminalContainerView.paste` override; OSC 52 delegates remain unchanged.

Tests: `Tests/SwiftTermTests/BicTermMouseTests.swift` uses XCTest for event gates,
exact SGR press/release/drag/hover/wheel output, legacy bytes, and modifiers.
`BicTermUITests/TerminalUITests.swift` verifies actual selection/copy/paste and
SGR drag delivery against sshd, plus a mouse-enabled Vim cursor move.

Limits: primary button only; vertical wheel only. Physical pointer hover,
wheel, two-finger scrolling, and Shift bypass need real-device validation.
Reapply hunks 6-7 in addition to the original five when rebasing the fork.

## Hosted accessory toolbar (production, hunk 8)

### Hunk 8 — `hostedAccessory` fallback (`iOS/iOSTerminalView.swift`)

```diff
+    // BICTERM-PATCH hunk 8: the app may host a TerminalAccessory in its own
+    // layout (…)
+    public weak var hostedAccessory: TerminalAccessory?
+
     /// Returns the inputaccessory in case it is a TerminalAccessory and we can use it
     var terminalAccessory: TerminalAccessory? {
         get {
-            _inputAccessory as? TerminalAccessory
+            (_inputAccessory as? TerminalAccessory) ?? hostedAccessory
         }
     }
```

BicTerm's session scenes never use UIKit's `inputAccessoryView` dock: with a
hardware keyboard attached (the common iPad case) UIKit docks the accessory at
the bottom of the screen OVERLAYING the terminal's bottom rows. Instead the
app nils `inputAccessoryView` on its `TerminalContainerView` surfaces and hosts
a `TerminalAccessory` (public initializer, unchanged) inside
`TerminalToolbarHostView`, where the strip participates in layout — the
terminal shrinks by the strip's height and the bottom row stays visible.

The hunk exists because the sticky `controlModifier` on the accessory feeds
hardware-key encoding at three sites (`terminalAccessory?.controlModifier` in
the presses/insert paths, plus `cancelTimer()` on resign). With
`_inputAccessory` nil, an app-hosted accessory would silently break sticky
ctrl; `hostedAccessory` keeps that lookup working. `_inputAccessory` keeps
precedence when both are set, so upstream behavior is byte-identical for any
consumer that does not set `hostedAccessory`.

Toolbar visibility policy (default hidden with a hardware keyboard via
`GCKeyboard.coalesced`, sticky explicit toggle, persistence) lives entirely
app-side (`BicTerm/Terminal/TerminalToolbar.swift`); the fork carries only
this lookup widening.

Tests: `BicTermTests/TerminalToolbarModelTests.swift` covers the heuristic,
persistence, and reset; `BicTermUITests/TerminalToolbarUITests.swift` toggles
the strip from the scene chrome, asserts the terminal frame shrinks by exactly
the strip height (no overlay), and verifies the explicit choice across
relaunches.

Reapply hunk 8 together with hunks 1-7 when rebasing the fork.

## Local selection reliability (production, hunk 9)

### Hunk 9 — feed preservation, drag pivot, Option bypass, and menu focus

- `Apple/AppleTerminalView.swift`: `feedPrepare()` clears selection only when
  reporting is allowed **and** `terminal.mouseMode != .off`, matching hunk 7's
  UIKit linefeed gate. Ordinary output chunks preserve local selection; remote
  mouse applications retain their existing redraw-clears-selection behavior.
- `iOS/iOSTerminalView.swift`: `panSelectionHandler` seeds the farther endpoint
  as pivot when an active-selection drag begins outside both handle zones.
  Distance is measured in buffer-linear cells; existing near-handle precedence,
  buffer-absolute rows, and pointer selection's `yDisp` conversion are unchanged.
- `modifierForcesLocalSelection` combines unconditional Option (`.alternate`)
  bypass with the existing conditional Shift bypass. Single/double/triple taps
  and `reportsMouse` use it, covering drag admission, wheel, and hover routing.
  Shift capture cannot override Option. Mouse encoders (including the meta bit),
  gesture failure chains, indirect-pointer-only drag initiation, and second-finger
  wheel promotion remain unchanged. Drag ownership is still chosen at admission.
- Local double/triple taps acquire first-responder focus before selecting and
  presenting the context menu.

Regression coverage in `Tests/SwiftTermTests/BicTermMouseTests.swift`: view feed
preserves selected text in mode off (string and byte-array chunks), clears it in
all four reporting modes, and UIKit-only tests exercise Option+Shift double-tap
with Shift capture enabled and active-selection dragging away from handles.
The existing exact-byte mouse tests remain intact. UIKit-only tests require an
iOS test destination; host `swift test` runs the shared feed and encoder tests.

Validation (2026-09-11): all seven `BicTermMouseTests` pass on the iPhone 17 Pro
simulator using the `SwiftTerm-Package` scheme. The isolated run sets
`EXCLUDED_SOURCE_FILE_NAMES=SelectionScrollTests.swift` because that unrelated
test file references macOS-only `HeadlessTerminal` and prevents the iOS test
target from compiling. No test source was removed. Host `swift test` passes all
85 XCTest cases (including the five host mouse tests); the 732-test Swift Testing
run reports five MetalRendererStatusTests shader-resource lookup failures
(`Failed to load Metal shader source: Apple/Metal/Shaders.metal`). Thus the full
fork suite is not green on this host, independently of the selection assertions.

Reapply hunk 9 with hunks 1-8 when rebasing. Search the two view files and the
regression test file for `BICTERM-PATCH hunk 9` markers.

## Reconnect mode reset (production, hunk 10)

### Hunk 10 — additive `Terminal.resetSessionModes()` (`Terminal.swift`)

Clears mouse reporting, Shift capture, mouse encoding, bracketed paste,
application cursor/keypad, and both normal/alternate keyboard-mode stacks.
Returns to the normal buffer with `activateNormalBuffer(clearAlt: true)`;
normal-buffer content and scrollback are not reset. Setting `mouseMode` uses
its existing observer so the view stops tracking remote mouse input.

DECSTR alone leaves mouse and paste modes enabled; RIS recreates the normal
buffer and loses the transcript. This explicit API is called by
`TerminalViewCache.resetSessionState(for:)` when the scene observes reconnecting.
It does not change remote DECSTR or RIS semantics.

`BicTermMouseTests.testSessionModeResetPreservesScrollback` checks mode reset,
both keyboard states, alternate-screen exit, and unchanged normal-buffer text.
Reapply hunk 10 with hunks 1-9; its source and test carry inline markers.

## OSC 52 clipboard write surface (production, hunk 11)

### Hunk 11 — typed `ClipboardWriteRequest` + `oscClipboardWriteRequest` delegate

**Pre-hunk state inspected on disk.** `Terminal.oscClipboard` already
parsed the `ESC ] 52 ; <sel> ; <payload> ST` sequence and called
`tdel?.clipboardCopy(source:content:)` after decoding the base64 payload.
The default `TerminalViewDelegate.clipboardCopy` was empty, so remote
writes were silently dropped — but the typed reasons (malformed base64,
oversized payload, empty/clear, foreground vs. background) had no surface
to the host. Read/query (`payload == "?"`) also routed through
`clipboardRead`, whose default returns `nil`. The fork's parse path was
already exactly the source of truth we needed; the gap was a typed
decision point.

The hunk adds an additive, typed request that surfaces every write
attempt at one delegate method so the host can apply a single policy at
one decision point.

- `Terminal.ClipboardWriteRequest` (struct): `rawBase64: Data`,
  `selection: String`, plus `isEmpty: Bool` and `decodedContent: Data?`
  accessors. The raw bytes are kept undecoded so malformed base64 stays
  diagnosable at the host.
- `TerminalDelegate.oscClipboardWriteRequest(source:request:)` and
  `TerminalViewDelegate.oscClipboardWriteRequest(source:request:)`: the
  new method, default deny. `TerminalView.oscClipboardWriteRequest`
  forwards to `terminalDelegate`; the `Apple/TerminalViewDelegate.swift`
  protocol is extended; the Mac view, Mac local-process view, and the
  iOS SwiftUI view default impl all gain the new symbol so the fork's
  package builds on every platform.
- `Terminal.oscClipboard`: read/query still routes through
  `clipboardRead` (default deny — non-negotiable per app policy). Every
  write attempt now builds a `ClipboardWriteRequest` and calls the new
  delegate method, regardless of base64 validity. The previous path
  silently dropped malformed base64; that information is now preserved
  for host diagnostics.

`Tests/SwiftTermTests/BicTermOSC52Tests.swift` (new, this hunk) covers
the parse-path contract: read/query is denied by default, empty payload
surfaces as `isEmpty == true`, malformed base64 surfaces with
`decodedContent == nil`, valid base64 surfaces with the decoded bytes,
`?` payload routes through `clipboardRead`, and the new delegate method
fires with a `ClipboardWriteRequest` exactly once per write attempt.

App-side policy (foreground gating, 100 KB cap, default-ON Settings
toggle, attribution toast, source label) lives entirely in
`BicTerm/Terminal/Osc52Clipboard.swift` and `Osc52Router.swift`; the
fork stays policy-free. The `clipboardCopy(source:content:)` fallback
is preserved as a byte-level shim so any consumer that hasn't adopted
the typed entry point keeps its old behavior — reapply is safe even
without a host-side upgrade.

Reapply hunk 11 with hunks 1-10. The hunk touches `Terminal.swift`,
`Apple/TerminalViewDelegate.swift`, `iOS/iOSTerminalView.swift`,
`iOS/SwiftUITerminalView.swift`, `Mac/MacTerminalView.swift`, and
`Mac/MacLocalTerminalView.swift`.
