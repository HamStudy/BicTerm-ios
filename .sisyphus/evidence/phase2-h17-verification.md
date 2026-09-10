# Phase 2 — H17 (task 17): herdr semantic input verification

Scope: iOS input → semantic Herdr FFI messages (keyboard, focus, resize, pointer).
Commit: `feat(app): herdr semantic input mapping with keyboard, focus, resize`.

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
| BicTermUITests/TerminalUITests (regression — injector modified) | PASS (6/6) | **FAIL (6/6)** — see anomaly | h17-terminal-iphone.xcresult, h17-terminal-ipad.xcresult |

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

## Anomaly: TerminalUITests on the iPad simulator (pre-existing / orthogonal)

All six TerminalUITests fail on the iPad destination with the app showing the
connections list ("No connections yet") — the `-uitest-terminal-preview`
launch-argument gate never engages, so no preview screen, no SSH connection,
no injector involvement. Failures reproduce across: the full suite, a targeted
two-test rerun, and a full-suite rerun after a hard `simctl shutdown`.

Attribution evidence that this is NOT caused by the H17 diff:

1. `git status`: the gate/preview files (`BicTerm/App/BicTermApp.swift`,
   `BicTerm/Terminal/TerminalPreviewController.swift`,
   `BicTerm/Terminal/TerminalRepresentable.swift`) are unmodified.
2. The identical build passes TerminalUITests 6/6 on the iPhone destination
   with the same launch-argument mechanism.
3. Launch arguments provably reach processes on the same iPad simulator: the
   launch-arg-gated HerdrInputUITests (`--uitest-herdr-replay`) pass 7/7 there.
4. 5 of 6 failing tests never arm the modified injector (`--uitest-hwkeys`
   absent); the 6th (`testHardwareKeyboardControlAndMetaKeys`) fails at the
   40 s preview-ready wait, before the injector would arm.
5. Last known green iPad terminal run: `.sisyphus/evidence/t12-ipad-nonhardware.log`
   (T12 era). No post-T12 iPad terminal evidence exists in `.sisyphus/evidence/`,
   so the breakage window is T13–T16 or the simulator environment, not H17.

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
