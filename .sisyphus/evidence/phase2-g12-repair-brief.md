# T12 repair continuation: INCOMPLETE

This continuation fixed independently reproduced navigation defects but did
not close the phase gate. The matrix remains 34 rows: 2 PASS, 3 NOT-LOCAL,
29 FAIL. No local acceptance gap was reclassified as NOT-LOCAL. No Herdr
work or plan-checkbox change was made.

## Proven repairs

1. **Coder selection after typing:** the iPhone failure hierarchy showed the
   server picker at y=793–845 behind the keyboard accessory toolbar at
   y=792–840, with the name field still focused. Clearing focus when changing
   protocol makes the new regression and the untouched protected
   reauthentication test pass. The connection editor uses page presentation
   sizing so its Coder controls are reachable in the iPad sheet as well.
2. **Saved-server row hit target:** the iPad row had a large untappable blank
   center because its plain button label contained a Spacer without a content
   shape. A center-coordinate tap failed before adding the rectangle content
   shape and passed afterward. The untouched protected save/edit test passed.
3. **Orphaned terminal window:** opening Alpha, terminating, and launching Beta
   left only an inert Terminal Session placeholder. The full-suite failure
   hierarchy independently showed that exact state. After snapshot resolution,
   orphaned windows now return to the connection list rather than remaining
   inert. Existing valid snapshots still use the original restoration path.
   The DEBUG session driver runs once per process across restored windows;
   preview launch mode is honored by terminal windows too.

The four new CoderEditorFocusUITests/WindowRelaunchUITests cases passed in
the final full suite on **both** canonical devices. They are not substituted
for the outstanding protocol acceptance rows.

## Remaining regression blocker

The hop failure recording shows **1222222** where the fixture intended
**12222**. The application correctly rejected the invalid port. The existing
ConnectionEditorUITests replacement helper silently continues when its
Select All menu lookup fails. A new behavioral regression asserts the final
field value instead of assuming replacement happened.

Three alternatives were attempted and retained in logs:

- Command-A selection: did not replace the old digits.
- Triple-tap selection: failed because the field was not hittable during
  keyboard/Form relayout.
- Trailing-edge coordinate tap followed by deletes: did not remove the old
  digits; the observed value was again 1222222.

After these three materially different failed approaches, source-fix attempts
stopped. The unsuccessful helper changes were restored to the original code.
The new failing regression is retained; no assertions, tests, or scope were
removed or weakened. Its latest iPad full-run failure was a not-hittable
event, so both selection correctness and input-layout stabilization need
resolution. Do not call this fixed or classify it as an environment exemption.

## Final fresh regression results

| Surface | iPhone | iPad |
|---|---|---|
| Full core | 314 tests, 15 skips, 0 failures | 314 tests, 15 skips, 0 failures |
| Full app unit | 81 tests, 0 failures | 81 tests, 0 failures |
| Full UI | 62 tests, 5 skips, 1 failure | 62 tests, 2 skips, 3 failures |

Remaining iPhone failure:

- SessionScenesUITests.testUnknownHostTrustPromptTrustsAndConnects: expected
  trust prompt absent. The attempted pre-UI uninstall reported the canonical
  iPhone was shutdown; the suite still ran, but this is not a clean-install
  proof. A correctly booted clean-install rerun is still required.

Remaining iPad failures:

- CoderAgentPickerUITests.testTwoAgentWorkspaceShowsPickerAndPersistsChoice,
  line 303, assertion failure.
- ConnectionEditorUITests.testReplacingDefaultPortDoesNotAppendToExistingDigits,
  not-hittable text field during event synthesis.
- PasswordAuthUITests.testPasswordDestinationPersistsAndNeverPrefills,
  not-hittable port field during event synthesis.

These observations supersede the first pass's 1/22 failure counts. The broad
iPad placeholder cascade is gone in the final run, but the suite is not green.

## Exact command forms and artifact index

All commands ran from the repository root with:

```sh
source scripts/env-local-caches.sh
export HOME="$PWD/.build-artifacts/Home"
export XDG_CACHE_HOME="$PWD/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-artifacts/ModuleCache"
```

For each pair below, substitute the exact `device` and `id` together:

- `device=iphone`, `id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E`
- `device=ipad`, `id=3686DD9C-ACA2-4A79-8968-A9C3572C8276`

Executed sequentially:

```sh
DEST_OVERRIDE="platform=iOS Simulator,id=$id" DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG=".sisyphus/evidence/phase2-g12-repair-core-$device.log" scripts/test-core.sh
xcodebuild test -scheme BicTerm -destination "platform=iOS Simulator,id=$id" -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO -only-testing:BicTermTests
xcrun simctl uninstall "$id" com.bicterm.app
xcodebuild test -scheme BicTerm -destination "platform=iOS Simulator,id=$id" -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -resultBundlePath "$PWD/.build-artifacts/xcresults/g12-repair-full-$device.xcresult" -parallel-testing-enabled NO -only-testing:BicTermUITests
```

Logs under `.sisyphus/evidence/`:

- `phase2-g12-repair-core-{iphone,ipad}.log`: full core output.
- `phase2-g12-repair-unit-{iphone,ipad}.log`: full app unit output.
- `phase2-g12-repair-full-{iphone,ipad}.log`: full UI output, no exclusions.
- `phase2-g12-focus-red.log`, `phase2-g12-focus-green.log`: focus regression.
- `phase2-g12-reauth-fixed.log`: protected iPhone test passes unchanged.
- `phase2-g12-row-hit-red.log`, `phase2-g12-editor-ipad-green.log`:
  untappable-center regression and green editor suite.
- `phase2-g12-save-ipad-fixed.log`: protected iPad save/edit test passes.
- `phase2-g12-window-red.log`, `phase2-g12-window-green.log`:
  orphaned-window regression before/after.
- `phase2-g12-port-red.log`, `phase2-g12-port-green-suite.log`,
  `phase2-g12-port-triple.log`, `phase2-g12-port-clear.log`: unresolved field
  replacement and the three unsuccessful approaches (names do not imply success).
- `phase2-g12-ipad-focus-full.log`: intermediate full iPad failure evidence.
- `phase2-g12-repair-default-build.log`, `phase2-g12-repair-appstore-build.log`:
  both arm64 Release builds succeeded.
- `phase2-g12-repair-isolation.log`: exact bridge/SDK, target-graph,
  bundle-presence and otool audits with default positive control; passed.

Build commands are the first brief's Release commands with
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`; exact invocations appear at the top of
each corresponding build log. No new dependencies were added.

The failure screenshot `.scratch/g12-ipad-hop/save-frame.png` was extracted
at 54 seconds from the actual XCTest recording and visually confirms the
invalid port. Full result bundles are retained explicitly under
`.build-artifacts/xcresults/`, avoiding Xcode's rolling Logs/Test retention.
Visual QA remains NEEDS WORK: functional failures remain, and successful
tests' recording exports supplied no retained attachments. No independent
visual-approval claim is made.

LSP reported no errors for all seven changed Swift files. Matrix structural
validation and its 9 tests / 10 assertions passed. `--gate` still rejects the
29 FAIL rows, correctly. `git diff --check` passed.

## Still required before approval

Resolve the remaining input/navigation failures, repeat correctly cleaned
full UI runs, execute the outstanding native-deployment acceptance scenarios
and complete the four-category sentinel logging audit. The first brief's
NOT-LOCAL list remains unchanged. This is a repair handoff, not a phase-gate
approval package.
