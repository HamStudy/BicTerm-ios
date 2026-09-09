# T12 focused UI repair — PASS

Scope: the four remaining UI failures and iPad window-per-new-connection
behavior only. This does **not** approve T12's protocol matrix or unblock
Herdr. Prior protocol work in the working tree is excluded from these UI
commits and from this verdict.

## Results on the current UI revision

| Destination | Full BicTermUITests | Result |
|---|---|---|
| iPhone 732CE8E1-F9EF-4020-BF93-5BA1AA365B0E | 63 tests; 5 pre-existing platform skips; 0 failures | PASS |
| iPad 3686DD9C-ACA2-4A79-8968-A9C3572C8276 | 63 tests; 2 pre-existing platform skips; 0 failures | PASS |

No skips were added, no assertions were weakened, and the complete suites ran
sequentially after successful bootstatus and uninstall operations. The
previously failing port replacement test remains enabled and is now green.

## Causes and red-to-green evidence

### iPad port replacement and password port hittability

Hypotheses: failed Select All selection; keyboard/layout obstruction; focus
moving to a different responder. The failure hierarchy showed a focused
`field-port` behind `PopoverDismissRegion`, with the iPad number-pad popover
active. This explains why further gestures against the underlying field
were not hittable, rather than indicating invalid port validation.

Changed the production port keyboard to `.numbersAndPunctuation` on iPad;
iPhone retains `.numberPad`. The original replacement helper is unchanged.

- Red: `phase2-g12-final-port-probe.log` and
  `.build-artifacts/xcresults/g12-final-port-probe.xcresult`.
- Green isolated replacement: `phase2-g12-final-port-keyboard.log`.
- Green full editor suites: `phase2-g12-final-ConnectionEditorUITests.log`
  (7 tests), `phase2-g12-final-PasswordAuthUITests.log` (3 tests).
- Final full runs assert the exact value `12222`, not `1222222`.

### iPad agent choice

Hypotheses: selection lost from the model; editor row offscreen; picker
action never fired. The fresh failure hierarchy still showed the Select
Agent screen after tapping main. The plain button's large blank center was
outside its hit shape; this was not a persistence loss.

Added `.contentShape(Rectangle())` to the picker row label.

- Red: `phase2-g12-final-CoderAgentPickerUITests.log`, failure at line 303.
- Green isolated case: `phase2-g12-final-agent-green.log`.
- Green complete CoderAgentPickerUITests in both final full UI runs, including
  selection return and persisted choice after relaunch.

### iPhone trust prompt

Hypotheses: stale trust state after failed uninstall; reset/pretrust race;
restored scene obscuring the owning prompt. The earlier uninstall had failed
because the device was shutdown. A successful `bootstatus -b` followed by
uninstall made the isolated case pass without changing trust production code
or its assertions. Both final full runs also pass the trust case.

- Earlier failure: `phase2-g12-repair-full-iphone.log`.
- Green clean isolated case: `phase2-g12-final-trust-clean.log`.
- This is a corrected setup with runtime proof, not a general flake claim.

### New iPad connections preserve distinct windows

Hypotheses: the terminal sheet switches its own displayed session; the new
session reuses an identity; sheet dismissal closes the original session.
The new scene-level regression failed with zero windows containing Alpha
after Beta opened. The new descriptor was distinct, but the terminal sheet
assigned it to `switchedSessionID`.

Both new-connection entry points now use `supportsMultipleWindows` and
`openWindow(id: "terminal", value: SessionID(...))`. This preserves regular-
width iPad behavior and avoids treating narrow iPad windows as iPhones.
Explicit existing-session selection still uses `switchedSessionID`.

- Red: `phase2-g12-final-new-window-red2.log`; the first harness attempt
  (`...-red.log`) exposed a missing wait for the sheet, corrected before
  the targeted red run.
- Green: `phase2-g12-final-new-window-green.log` (all 3 WindowRelaunch tests).
- Final iPad test asserts exactly one Alpha window and one Beta window,
  no Alpha title inside Beta's window, preserved original terminal marker,
  and both sessions active. Existing restoration tests remain green.
- Screenshots show the foreground window; distinct ancestry is proved by
  XCTest, not inferred from two images. These captures use the canonical
  full-size iPad; no manual arbitrary Stage Manager resize is claimed.

## Exact full-suite commands

Executed from `/Users/richard/code/BicTerm`, with repository-local caches:

```sh
source scripts/env-local-caches.sh
export HOME="$PWD/.build-artifacts/Home"
export XDG_CACHE_HOME="$PWD/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-artifacts/ModuleCache"

xcrun simctl bootstatus 732CE8E1-F9EF-4020-BF93-5BA1AA365B0E -b
xcrun simctl uninstall 732CE8E1-F9EF-4020-BF93-5BA1AA365B0E com.bicterm.app
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -resultBundlePath "$PWD/.build-artifacts/xcresults/g12-ui-scoped-iphone.xcresult" -parallel-testing-enabled NO -only-testing:BicTermUITests

xcrun simctl bootstatus 3686DD9C-ACA2-4A79-8968-A9C3572C8276 -b
xcrun simctl uninstall 3686DD9C-ACA2-4A79-8968-A9C3572C8276 com.bicterm.app
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=3686DD9C-ACA2-4A79-8968-A9C3572C8276' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -resultBundlePath "$PWD/.build-artifacts/xcresults/g12-ui-scoped-ipad.xcresult" -parallel-testing-enabled NO -only-testing:BicTermUITests
```

Full output: `.sisyphus/evidence/phase2-g12-ui-scoped-{iphone,ipad}.log`.
Raw logs, result bundles and PNGs are retained repository-local ignored
artifacts; this brief, review summaries and compact evidence indexes are committed.
Focused invocations appear at the top of each red/green log; they use the
same scheme and canonical destination with the single named suite/test.

The seven UI source/test files were SHA-256 pinned before both full runs and
verified unchanged afterward (`phase2-g12-ui-scoped-sources.sha256`). Earlier
exported PNGs predated the latest file timestamps, so both full suites and
all captures were regenerated rather than reusing that evidence. The new
12/12 capture signature, dimension and freshness checks passed in
`phase2-g12-ui-capture-validation.log` before fresh review dispatch.

## Visual QA — both fresh independent passes PASS

All 12 fresh PNGs were inspected by new read-only reviewers:

- Pass A, functional/design integrity: `bg_b6316585`, session
  `ses_f788803a0ffeWGdHrHmrXEEvRq` — PASS, high confidence (0.9), 12/12, no blockers.
- Pass B, visual fidelity/accessibility: `bg_cfe6db4c`, session
  `ses_f788802b5ffezcyaNRudWXu5Om` — PASS, high confidence (~0.95), 12/12, no blockers.

Summaries: `phase2-g12-ui-review-a.md`, `phase2-g12-ui-review-b.md`.
Export index: `phase2-g12-ui-scoped-export.log`. The capture validation log
lists all 12 exact PNG paths. Each following directory is under
`.sisyphus/evidence/`, with a manifest mapping filenames to states:

| Directory | States | PNG count |
|---|---|---|
| phase2-g12-ui-captures-iphone-windows | original / second | 2 |
| phase2-g12-ui-captures-ipad-windows | original / second | 2 |
| phase2-g12-ui-captures-iphone-agent | picker / selected in editor | 2 |
| phase2-g12-ui-captures-ipad-agent | picker / selected in editor | 2 |
| phase2-g12-ui-captures-iphone-port | focused / replaced | 2 |
| phase2-g12-ui-captures-ipad-port | focused / replaced | 2 |

Non-blocking observations retained: system Done accessory grazing lower form
content while typing; faint keyboard glyphs behind the terminal accessory
bar; normal nav-bar scroll-under; non-fatal UIKit reparenting warning in the
iPad agent attachment. The edited port field remains unobstructed. No fixture
network-address text is reproduced.

## Scope and preservation

UI sources: BicTermApp.swift, ConnectionListContainer.swift,
ConnectionEditorView.swift, CoderAgentPickerView.swift. Direct tests:
WindowRelaunchUITests.swift, ConnectionEditorUITests.swift,
CoderAgentPickerUITests.swift. All previous Coder editor focus/row-hit and
restoration repairs are preserved.

Diagnostics were requested for all seven files. Standalone SourceKit could
not resolve target modules in BicTermApp/ConnectionListContainer; other UI
files had no diagnostics. Authoritative xcodebuild compiled and executed the
complete suites successfully. Whitespace audit passed.

Protected dirty test files and untracked governing specifications are unchanged.
No dependencies were added. No protocol-matrix changes are staged or committed
in this focused pass; earlier non-UI work remains separate. T12 and Herdr
phase approval are still outside this scoped UI PASS.
