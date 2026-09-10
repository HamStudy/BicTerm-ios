# Phase 2 — H17 (task 17): herdr semantic input verification

Scope: iOS input → semantic Herdr FFI messages (keyboard, focus, resize, pointer).
Commit: `feat(app): herdr semantic input mapping with keyboard, focus, resize`.
Follow-up: `fix(app): gate herdr workspace window root for terminal preview UI tests`
(resolves the iPad TerminalUITests failure initially reported as an anomaly below).

## Destinations

- iPhone simulator `732CE8E1-F9EF-4020-BF93-5BA1AA365B0E` (iPhone 17 Pro, iOS 26.x)
- iPad simulator `3686DD9C-ACA2-4A79-8968-A9C3572C8276` (iPad Pro 13-inch M5, iOS 26.x)

Common flags: `-project BicTerm.xcodeproj -derivedDataPath .build-artifacts/DerivedData/h17`,
one `-only-testing:` suite per invocation, result bundle removed before each rerun.

## Matrix (all green unless noted)

| Suite | iPhone | iPad | Result bundles |
|---|---|---|---|
| BicTermTests/HerdrSessionModelTests | PASS | PASS | h17-model-{iphone,ipad}.xcresult |
| BicTermTests/HerdrKeyMapperTests (8) + HerdrSessionInputTests (13) | PASS | PASS | h17-unit-{iphone,ipad}.xcresult |
| BicTermUITests/HerdrWorkspaceUITests (regression — workspace view modified) | PASS | PASS | h17-workspace-{iphone,ipad}.xcresult |
| BicTermUITests/HerdrInputUITests (7, new) | PASS (7/7) | PASS (7/7) | h17-ui-{iphone,ipad}.xcresult |
| scheme HerdrClientCore (resize passthrough + bounds test) | PASS | n/a | h17-core-iphone.xcresult |
| BicTermUITests/TerminalUITests (regression — injector modified) | PASS (6/6) | PASS (6/6) after the scene-gate fix (below) | h17-terminal-iphone.xcresult → h17fix-terminal-{iphone,ipad}.xcresult |

Bundles live under `.build-artifacts/xcresults/`.

## UI-test input delivery (load-bearing design point)

XCUI `typeKey` AND `typeText` both no-op against the herdr replay scene on the
simulator — even with the field as key-window scene responder and a live RTI
text-input session (device log: `Reloading input views for key-window scene
responder: <BicTerm.HerdrInputField>`, `fromBecomeFirstResponder: 1`,
`automaticKeyboard: 1`; no synthesized events ever arrive). The DEBUG
`--uitest-hwkeys` injector therefore carries all synthesized input:

- keys/nav chords → real `UIKey`/`UIPress` instances through the field's
  `pressesBegan`/`pressesEnded` overrides (pre-existing mechanism);
- `text:<string>` → one `insertText` per grapheme (soft-keyboard granularity);
- `await:echo:<needle>` → polls the mirrored input echo
  (`HerdrWorkspaceUITest.currentInputEcho`) so commits can be ordered after a
  tap retarget.

## Resolved: iPad TerminalUITests failure was a missing scene gate (follow-up commit)

The iPad 6/6 failure was initially misattributed to the environment; the
empirical root cause (proven by the phase lead): the "Herdr Workspace"
WindowGroup in `BicTerm/App/BicTermApp.swift` (T16) had NO
`-uitest-terminal-preview` gate, unlike the main and "Terminal" groups.
`HerdrWindowRoot`'s nil-state renders `ConnectionListContainer`
("No connections yet"), and iPadOS persists scene sessions across launches
AND hard shutdowns — once a herdr UI test opened a herdr window, every
later TerminalUITests launch restored the stale herdr scene showing the
connection list; the preview scene was never created and `previewState`
never appeared, so all six tests timed out at 40 s. Proof: the process
argv contained `-uitest-terminal-preview` and the installed binary was the
correct Debug build, yet the connection list rendered; after
`simctl uninstall` the identical test passed in ~7 s. The earlier
clean-install attempt targeted a nonexistent bundle ID
(`com.bicterm.BicTerm` — the real one is `com.bicterm.app`), which is why
uninstalling "didn't help".

Fix: the herdr group now mirrors the same `#if DEBUG`
`-uitest-terminal-preview` gate, rendering `TerminalPreviewScreen()` under
the flag; production behavior is unchanged (the `#else` branch is the
pre-fix code). Gate audit conclusion: of all `-uitest-*` flags, only
`-uitest-terminal-preview` selects which root view renders.
`--uitest-force-connection-list` is a sub-branch inside TerminalWindowRoot
(and the herdr nil-state already shows the connection list, which is that
flag's intent); `--uitest-herdr-replay`, `--uitest-hwkeys`, and
`--uitest-pretrust-fixtures` are data/behavior knobs with no root-view
impact. No other gate needed mirroring.

Ordering-repro verification (iPad `3686DD9C-ACA2-4A79-8968-A9C3572C8276`,
no uninstall between legs — the exact ordering that failed 6/6 pre-fix):

1. HerdrInputUITests + HerdrWorkspaceUITests → PASS (creates the herdr
   scene sessions): h17fix-herdr-input-ipad-1.xcresult,
   h17fix-herdr-workspace-ipad-1.xcresult
2. TerminalUITests full suite WITHOUT uninstall → PASS 6/6 (64.7 s total —
   healthy per-test timing vs. 6 × 46 s timeouts pre-fix):
   h17fix-terminal-ipad.xcresult
3. HerdrInputUITests + HerdrWorkspaceUITests again → PASS:
   h17fix-herdr-input-ipad-2.xcresult, h17fix-herdr-workspace-ipad-2.xcresult
4. iPhone `732CE8E1-F9EF-4020-BF93-5BA1AA365B0E`: TerminalUITests 6/6 +
   both herdr suites PASS: h17fix-terminal-iphone.xcresult,
   h17fix-herdr-input-iphone.xcresult, h17fix-herdr-workspace-iphone.xcresult

The T12-era green iPad run (t12-ipad-nonhardware.log) predates T16's
WindowGroup — consistent with the failure being introduced by T16's
ungated group and merely unmasked by H17's herdr UI suites, not by the
simulator environment.

## Fixture note (pre-existing script bug, not fixed in H17)

`scripts/fixtures-up.sh` chmods host keys via `chmod 600 "$KEYS"/host_keys/*`
but the keys live in `$SSHD_DIR/host_keys/` — the glob never matches, and
git checkouts leave the committed keys at 0644, so sshd refuses them
("no hostkeys available"). Local repair used for this run:
`chmod 600 Fixtures/sshd/host_keys/* Fixtures/sshd/host_key_alt/*`
(permission bits only — no repo diff).

## How to reproduce

```bash
# herdr suites (iPhone id shown; swap the iPad id for the second leg)
xcodebuild test -project BicTerm.xcodeproj -scheme BicTerm \
  -destination "platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E" \
  -derivedDataPath .build-artifacts/DerivedData/h17 \
  -resultBundlePath .build-artifacts/xcresults/<name>.xcresult \
  -only-testing:<Suite>

xcodebuild test -project BicTerm.xcodeproj -scheme HerdrClientCore \
  -destination "platform=iOS Simulator,id=732CE8E1-..." \
  -derivedDataPath .build-artifacts/DerivedData/h17 \
  -resultBundlePath .build-artifacts/xcresults/h17-core-iphone.xcresult

# terminal regression needs loopback fixtures first:
scripts/fixtures-up.sh   # chmod host keys 600 first on a fresh checkout
```
