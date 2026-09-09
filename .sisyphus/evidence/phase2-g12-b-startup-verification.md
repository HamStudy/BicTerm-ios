# Startup slice verification follow-up

Date: 2026-09-09

## Verified results

- Existing native startup evidence: four Core tests, zero failures in
  `phase2-g12-b-startup-tests.log`; two explicit-start app tests, zero failures
  in `phase2-g12-b-auto-final.log`.
- Fresh resolver regression: nine tests, zero failures in
  `phase2-g12-b-startup-resolver-regression.log`.
- Blocking unknown-lifecycle regression: the new test failed because resolution
  returned an endpoint before observing the subsequent startup error. Removing
  the unknown-state bypass from both readiness paths produces ten passing
  resolver tests in `phase2-g12-b-startup-unknown-green.log`; the failing run is
  `phase2-g12-b-startup-unknown-red.log`. The native four-test Core suite and
  two-test app suite were rerun successfully after this repair.
- Fresh transport regression: nineteen tests, zero failures in
  `phase2-g12-b-startup-transport-regression.log`.
- Pinned Coder v2.36.4 CLI comparison: both auto-wait policies passed in
  `phase2-g12-b-startup-cli-comparison.log`. Command:
  `CODER_STARTUP_PREPARE_ONLY=1 bash scripts/test-coder-startup.sh`, then
  `ruby scripts/test-coder-startup-cli.rb`. The blocking command remained
  pending until release; the nonblocking command returned its expected
  output while the script remained held. Both CLI processes exited zero.
- `ruby scripts/verify-coder-matrix.rb`: structure passes, 34 rows;
  PASS=24, FAIL=7, NOT-LOCAL=3.
- `ruby scripts/test-coder-matrix.rb --seed 1`: nine tests, ten assertions,
  zero failures, errors, or skips.
- `ruby scripts/verify-coder-matrix.rb --gate`: nonzero exit, reporting
  `phase gate INCOMPLETE: FAIL rows remain`. This is not gate approval.
- `GIT_MASTER=1 git diff --check`: passes.

Both fresh regression runs used `scripts/test-core.sh`, canonical iPhone
destination `732CE8E1-F9EF-4020-BF93-5BA1AA365B0E`, repository-local
`.build-artifacts/DerivedData/g12-core`, and the respective
`BicTermCoreTests/CoderWorkspaceResolverTests` or
`BicTermCoreTests/CoderTransportTests` ONLY_TESTING filter. Cache and temporary
paths came from `scripts/env-local-caches.sh`; HOME, XDG_CACHE_HOME, and
CLANG_MODULE_CACHE_PATH were overridden to repository-local paths.

## Diagnostic limitations

LSP checks ran on all nine changed Swift source/test files. Workspace model,
transport error, app starter, and native Core startup test returned no
diagnostics. Resolver, transport, and jump builder checks could not resolve
same-module types. The app startup test reported missing BicTermCore. These
are not clean LSP results; the successful Xcode test builds provide compiler
verification for the current patch.

The additional resolver regression file reported missing XCTest in SourceKit;
its Xcode test run compiled and passed.

The new CLI comparison script passed `ruby -c` and its live run. Ruby LSP
is unavailable and installation was previously declined.

## Remaining acceptance work

A10, A19-A22, A32, and A34 remain FAIL. Full Core runs on both canonical
destinations and final gate approval remain outstanding. Blocking scripts now
require ready lifecycle state; an unknown state no longer bypasses the wait.

A10 source inspection located dormancy refusal in CoderStartFlowView.run,
before invoking the starter, and parameter-mismatch refusal in
CoderWorkspaceStarter.start, before POST. This is source inspection only,
not live acceptance evidence. No UI or protected file was modified.
