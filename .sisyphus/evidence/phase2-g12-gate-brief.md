# T12 Coder phase gate: INCOMPLETE

Date: 2026-09-08. Fresh task session; no previous T12 session was reused.

**Do not approve or mark task 12 complete. Do not dispatch Herdr tasks 13–20.**
This package records a blocked gate, not completed acceptance. The plan and
the two governing specifications were not edited. Explicit user approval
has not been requested or recorded.

## Results

- Matrix: 34 verbatim normative rows, 2 PASS, 3 NOT-LOCAL, 29 FAIL.
  FAIL means insufficient acceptance evidence, not necessarily a reproduced
  implementation defect. Each row explains the remaining requirement.
- Core, iPhone: 314 executed, 15 skipped, 0 failures (299 non-skipped).
- Core, iPad: 314 executed, 15 skipped, 0 failures (299 non-skipped).
- App unit tests: 81 executed, 0 failures on each destination.
- Full UI, iPhone: 57 executed, 5 skipped, **1 failure**.
- Full UI, iPad: 57 executed, 2 skipped, **22 failures**.
- CoderAgentSelectionUITests: 6 passed on each destination within those full
  UI runs. These are DEBUG fixture tests, not native deployment coverage.
- Native CoderTransportConformanceTests: all 9 passed on each destination,
  including live printf, remote resize, suspend/resume, and close.
- Matrix verifier behavioral tests: 9 tests, 10 assertions, 0 failures;
  missing/altered/duplicate rows, missing evidence, invalid taxonomy, and
  FAIL rejection in gate mode are exercised through process exit status.
- Release arm64 builds: default and AppStore succeeded; three-layer
  AppStore isolation audit retained with default positive control.
- Pinned official CLI: v2.36.4+10fd510, command printed
  `bicterm-g12-cli-ok` in 0.272 seconds. This is a reference, not proof that
  OpenSSH works through BicTerm's raw bridge.

## Blocking regression evidence

The iPhone full run and a subsequent isolated run both failed
`CoderServersUITests.testCoderReauthenticateNavigatesToServerEditor` at
line 333: the `Expired Server` button was not found after opening the server
picker. The isolated rerun is not green and cannot erase the full-run failure.
The protected test file was read, not modified. Root cause has not been
confirmed; do not label this a harmless flake or blame the existing dirty edit.

The iPad run failed two CoderServers tests, two ConnectionEditor tests, one
PasswordAuth test, four SessionScenes tests, seven SessionSwitcher tests,
and all six Terminal tests. Failures include missing picker/credential
elements and missing Alpha/terminal preview scenes. Persistent scene state,
test-query drift, and app navigation regressions are hypotheses, not proven
causes. No weakening or selective exclusion of tests was applied.

The first iPhone core run exceeded the tool's 120-second timeout. Its partial
log is retained, and a full retry with a larger timeout passed. Before iPad
UI testing, uninstall initially reported a shutdown simulator; the canonical
device was explicitly booted and uninstall repeated before the full UI run.

The first unrestricted Release build attempted x86_64 as well as arm64 and
failed because the pinned XCFramework has no x86_64 slice. Retrying with
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` matched the canonical hardware and passed.
This is not a claim of Intel simulator support.

## Acceptance work still required

The matrix is structurally complete but acceptance is not. In particular:

- Execute native fixture invalid-token and permission-hidden-404 scenarios.
- Provision multiple agents; prove ambiguity, exact name and UUID, stale UUID.
- Capture T6 start mutation counts for policy off/on and lost-response recheck.
- Exercise dormancy and parameter mismatch without silent mutation.
- Provision blocking/nonblocking and timeout/error startup script variants.
- Force and observe direct, relay-only, server-disable-direct, custom-upgrade
  rejection/fallback, and forced WebSocket paths. The pinned server **does**
  expose `--derp-force-websockets`; claiming this unforceable would be false.
- Inject dynamic DERP-map update, coordinator reset, expired resume token,
  agent restart, and workspace rebuild with stream/no-replay assertions.
- Prove non-PTY binary stdout, stderr/exit status, >4 MiB streaming, half-close
  drain, stdout failure cleanup, and concurrent distinct-user isolation.
- Complete a sentinel log audit for user/resume tokens, keys and terminal
  contents. The narrower current fixture-token/password scan passed, but
  is not substituted for this full normative security row.
- Resolve and rerun the full failing UI regressions on both destinations.

These are not silently reclassified as NOT-LOCAL. A capability probe or a
passing neighboring unit test does not establish the required outcome.

## NOT-LOCAL list and optional live items

- A18: `needs-private-CA`. The environment probe found no approved file via
  `CODER_PRIVATE_CA_FILE`; the native fixture uses HTTP on loopback.
  **Optional live item:** an authorized private-CA/reverse-proxy deployment,
  validating trust/auth independently across REST, coordinator and relay.
- A28 and A29: `scope-explained`. Permanent v1 session-channel-only exclusion,
  cited in plan Scope / Out of scope line 32 and task 12 line 465.
  **Not optional live items.** No SFTP or TCP-forwarding claim is made.
- No rows are classified `needs-live-deployment` or `needs-physical-network`:
  the required attempts have not established those limitations. Local gaps
  stay FAIL rather than being moved into an optional user handoff.

## Exact execution context

All commands ran from `/Users/richard/code/BicTerm`. Build/test/fixture
commands used this preamble (no credential values included):

```sh
source scripts/env-local-caches.sh
export HOME="$PWD/.build-artifacts/Home"
export XDG_CACHE_HOME="$PWD/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-artifacts/ModuleCache"
```

Canonical destinations:

- iPhone: `platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E`
- iPad: `platform=iOS Simulator,id=3686DD9C-ACA2-4A79-8968-A9C3572C8276`

Full core commands (both executed, no ONLY_TESTING override):

```sh
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-core-iphone-retry.log' scripts/test-core.sh
DEST_OVERRIDE='platform=iOS Simulator,id=3686DD9C-ACA2-4A79-8968-A9C3572C8276' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-core-ipad.log' scripts/test-core.sh
```

App and UI commands (executed individually, UI suites sequentially):

```sh
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO -only-testing:BicTermTests
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO -only-testing:BicTermUITests
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=3686DD9C-ACA2-4A79-8968-A9C3572C8276' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO -only-testing:BicTermTests
xcrun simctl boot 3686DD9C-ACA2-4A79-8968-A9C3572C8276
xcrun simctl bootstatus 3686DD9C-ACA2-4A79-8968-A9C3572C8276 -b
xcrun simctl uninstall 3686DD9C-ACA2-4A79-8968-A9C3572C8276 com.bicterm.app
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=3686DD9C-ACA2-4A79-8968-A9C3572C8276' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO -only-testing:BicTermUITests
```

Release checks:

```sh
xcodebuild build -scheme BicTerm -configuration Release -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-default" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
xcodebuild build -scheme BicTerm-AppStore -configuration AppStore-Release -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' -derivedDataPath "$PWD/.build-artifacts/DerivedData/g12-appstore" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

The isolation log records exact shell-expanded `otool`, bundle-presence,
build-target and `strings` commands. The symbol pattern was
`CoderNet(Start|DialSSH|Rebind|Close|Version|FreeString|SetLogCallback)|workspacesdk|codersdk`,
not the allowed pure-Swift `CoderNetEvent` name.

Official CLI environment and command:

```sh
export CODER_CONFIG_DIR="$PWD/Fixtures/run/coder-dev/config"
export CODER_CACHE_DIRECTORY="$PWD/Fixtures/run/coder-dev/cache"
export CODER_USE_KEYRING=false
set -a; source Fixtures/run/coder-dev.env; set +a
Fixtures/run/coder-bin/coder ssh --disable-autostart --wait auto --log-dir "$PWD/.scratch/g12-cli" bicterm-host -- printf bicterm-g12-cli-ok
```

The first CLI attempt failed because its repository-local logging directory
did not exist. Creating `.scratch/g12-cli` resolved that invocation error;
both attempts remain in the log. Credentials were passed only via environment.

## Evidence index

All following paths are relative to `.sisyphus/evidence/`:

The brief and compact matrix/validator/locality/CLI evidence are committed.
Large raw build, regression and fixture logs remain repository-local ignored
artifacts, consistent with the existing evidence directory; retain this
checkout for the full log and xcresult review.

- `phase2-g12-matrix.log`: generator/structural validation and closed-gate result.
- `phase2-g12-matrix-red.log`: failing-first verifier test run (script absent).
- `phase2-g12-matrix-tests.log`: verifier behavioral tests, 9/9.
- `phase2-g12-matrix-explanation-red.log`: failing-first unexplained-taxonomy case.
- `phase2-g12-fixtures.log`: SSH/stub/UDS fixture setup.
- `phase2-g12-coder-fixture.log`: native Coder fixture setup and version.
- `phase2-g12-core-iphone.log`: initial interrupted core run.
- `phase2-g12-core-iphone-retry.log`, `phase2-g12-core-ipad.log`: complete core runs.
- `phase2-g12-regression-iphone.log`, `phase2-g12-regression-ipad.log`:
  each contains full app unit then full UI output, including failures.
- `phase2-g12-reauth-isolated.log`: same iPhone failure in isolation.
- `phase2-g12-processes.log`: process inventory before isolated reproduction.
- `phase2-g12-default-build.log`: unsupported x86_64 Release attempt.
- `phase2-g12-default-arm64-build.log`, `phase2-g12-appstore-build.log`:
  successful canonical-architecture Release builds.
- `phase2-g12-isolation.log`: AppStore absence checks and default symbol matches.
- `phase2-g12-cli-reference.log`: official version, attempts and latency.
- `phase2-g12-cli-help.log`, `phase2-g12-server-help.log`: pinned CLI probes.
- `phase2-g12-locality.log`: private-CA availability and scope citations.
- `phase2-g12-fixture-secret-audit.log`: current fixture-secret scan (limited scope).
- `phase2-g12-validation.log`: Ruby syntax checks and whitespace audit.

The full xcodebuild logs identify their repository-local `.xcresult` bundles
under `.build-artifacts/DerivedData/g12-{core,app}/Logs/Test/`.

LSP diagnostics were requested for both Ruby files; the configured Ruby LSP
is not installed (`rubocop` command missing). No dependency was installed.
Ruby syntax checks and executable behavioral tests are available instead;
this is an explicit diagnostic limitation, not a clean LSP claim.

## Handoff

Atlas must keep T12 unchecked. This evidence is suitable for reporting the
blocker and planning remaining acceptance work, **not for approval of the
Coder phase**. Preserve the protected dirty files and untracked governing
specs. Do not begin Herdr implementation as a workaround for missing Coder
acceptance coverage.
