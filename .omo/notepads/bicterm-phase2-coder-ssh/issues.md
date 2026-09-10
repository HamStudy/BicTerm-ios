# Issues — bicterm-phase2-coder-ssh

Problems and gotchas encountered during work on this plan.

_Auto-scaffolded by /start-work. Append new entries below - never overwrite._

---

## Resolved — T11 production diagnostics gap (2026-09-08)

- The original T11 implementation displayed Coder diagnostics but had no
  production route from Go `networkPathChanged` events to the owning scene.
  The repair adds a Swift-compatible Go event envelope, one process-wide Swift
  stream, and generation-guarded coordinator delivery to scene diagnostics.
- Canonical iPad acceptance initially failed because keyboard-dismiss fallback
  gestures ran even when no keyboard existed and because restored terminal
  windows obscured the connection list after relaunch. Both failures are now
  covered by the passing six-test iPhone and iPad suites.

## T12 blocked gate (2026-09-08)

- Fresh full runs: core 314/15 skipped/0 failed and app unit 81/0 failed on
  each canonical destination; UI iPhone 57/5 skipped/1 failure, iPad
  57/2 skipped/22 failures. Full evidence is in phase2-g12-regression-*.log.
- The protected CoderServersUITests reauthentication test fails at line 333
  in the full iPhone suite and alone: Expired Server button is not found.
  Do not treat this as a transient failure or modify the protected file.
- Coder v2.36.4 exposes --derp-force-websockets. It is not honest to call
  that acceptance row unforceable merely because the fixture has not enabled it.
- Release simulator builds must target arm64 for the current CoderNet
  XCFramework. An unrestricted Release invocation also attempts x86_64 and
  fails on undefined CoderNet bridge symbols; ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  builds both default and AppStore successfully.
- Matrix structural validation is separate from phase acceptance. The new
  verifier's --gate mode rejects FAIL rows; a structurally valid inventory
  must not be presented as a passing gate. See phase2-g12-gate-brief.md.

## Resolved — remaining T12 UI failures (2026-09-09)

- Full UI suites now pass on both canonical simulators: 63 tests each,
  iPhone 5 existing skips and iPad 2 existing skips, zero failures.
- Port replacement now produces 12222 using the existing helper; the iPad
  numberPad popover was the obstruction, not a need for stronger gestures.
- Persisted agent selection passes after fixing the choice row hit shape.
- New Connection from an existing iPad terminal creates another window and
  preserves the original title, output and active session. Existing-session
  switching and restoration are unchanged and remain green.
- This closes only the scoped UI repair. Protocol-matrix acceptance and
  Herdr approval remain separate work for Atlas.

## Open — T12 A31 stdout-failure teardown (2026-09-09)

- The raw OpenSSH /usr/bin/yes case remains alive after its local stdout
  reader closes, exceeding 15 seconds. The harness cleans its own process
  group and records FAIL. Active CoderNet handle cancellation does pass.
- Checkpoint matrix is PASS=13, FAIL=18, NOT-LOCAL=3. The missing progress
  brief has been created; no phase approval is implied by checkpoint commits.

## Resolved — A31 stdout-failure teardown (2026-09-09)

- Native stdout-failure and active-cancellation cases pass direct and relayed.
  Go regressions cover both write-error and end-of-write request teardown.
- See phase2-g12-a31-investigation.md for local x/crypto source references
  and before/after OpenSSH packet evidence. Matrix is now 14/17/3.

## T12 phase gate recorded [~] (2026-09-09)

- T12 marked `[~]`: acceptance criteria 1 and 2 are verified `[x]` (matrix
  31 PASS / 0 FAIL / 3 NOT-LOCAL, `--gate` exit 0, core 328/0 both
  destinations, UI 63/0 both destinations, `git diff --check` clean).
- Criterion 3 (user okay) is presented and awaiting an explicit user
  decision; the plan's own PHASE GATE (user directive, line 468) forbids
  Wave-7 (Herdr) dispatch without it. Unblock by flipping `[~]` back to
  `[x]` once the user approves.

## Full remaining tail recorded [~] (2026-09-09)

- Tasks 13-20 and F1-F4 marked `[~]`: they are gated behind the T12 phase
  gate (user okay, plan line 468), not individually escalated. None can be
  dispatched without the user's explicit approval.
- On user approval: flip T12 `[~]` -> `[x]` (criterion 3), reset each
  dispatched task `[~]` -> `[ ]` as its wave starts, `[x]` on verified
  completion. F1-F4 flip to `[ ]` only after task 20, then to `[x]` on
   APPROVE per the wave's own user-okay rule.

## T13 prerequisite stop — INCOMPLETE (2026-09-09)

- Preflight installed targets: aarch64-apple-darwin and
  wasm32-unknown-unknown only. Required aarch64-apple-ios and
  aarch64-apple-ios-sim targets are missing; cargo deny --version exits 101
  (no such command). No external installation attempted.
- Active toolchain is external and the cache script does not redirect
  RUSTUP_HOME. Resume with repository-local toolchain/targets and cargo-deny;
  local provisioning was not attempted, and is not claimed impossible.
- Stopped before clone/extraction. No build, tests, golden frames, license
  inventory, exclusion audit, upstream engagement, or completion commit.
  Structural extraction feasibility remains unassessed, not disproven.
- Evidence: .sisyphus/evidence/phase2-h13-preflight.md. Plan and protected
  files untouched; T14/T16 are not unblocked by this preflight record.

## T13 provisioning resolved; extraction incomplete (2026-09-09)

- Repository-local Rust 1.98.1 now includes both iOS targets; cargo-deny
  0.20.2 is installed under `.build-artifacts/tools`. Previous missing-tool
  blocker is resolved without external installation.
- Corrected source-boundary probes fail: protocol 33 compiler errors;
  protocol plus endpoint coordinator 95. Full logs are in
  `.sisyphus/evidence/phase2-h13-{protocol-boundary-corrected,coordinator-boundary}.log`.
  Initial probe feature/module-path errors were corrected and are not
  treated as evidence of upstream coupling.
- Exact load-bearing seams are documented in
  `Vendor/herdr/EXTRACTION_ESCALATION.md`: frozen data/conversions, native
  writer/supervisor, projection/input cleanup, and presentation replay.
  Missing imports are not proof of structural impossibility; no production
  refactoring patches were attempted. T13 remains incomplete, not complete
  by escalation. Full crate extraction still needs execution.
- No shipping workspace, golden fixtures, target-resolved license allowlist,
  cargo-deny audit, exclusion-audit pass, or submitted upstream engagement.
  The three passing health tests and iOS probe builds do not unblock T14/T16.

## T13 prior extraction blocker resolved; retained risks

- Both crates now compile and all 122 tests pass; the initial probe-only
  incomplete status is superseded. There is no structural-impossibility
  escalation. The plan checkbox remains untouched.
- cargo-deny initially rejected bincode 2.0.1 as unmaintained under
  RUSTSEC-2025-0141 (no safe upgrade). `deny.toml` contains one explicit,
  documented maintenance exception to preserve the frozen generation-1 codec.
  This is retained maintenance risk, not a vulnerability fix or silent waiver.
- Unknown and unlicensed packages still fail the audit, demonstrated with
  negative metadata cases. No source or vulnerability exception was added.
- LSP requests for both crate trees timed out; Cargo/rustfmt verification is
  green, but no clean LSP result is claimed.
- Full desktop UI interaction reducers are deliberately not imported. The
  extracted activation machine and neutral state API require native callers
  to settle source gestures, apply target replay and qualify shared state by
  viewer. These boundaries are explicit in EXTRACTION_ESCALATION.md/README.md.
- Upstream engagement is a tracked unsubmitted Discussion draft, not a posted
  issue/PR or upstream approval. No tasks 14–16 were executed in this lane.

## T14 residuals (2026-09-10)

- scripts/build-appstore.sh does not pass ARCHS=arm64 ONLY_ACTIVE_ARCH=YES,
  so an AppStore-Release simulator build fails on x86_64 with undefined
  HerdrCore symbols (arm64-only xcframework). T14 ran the AppStore flavor
  via direct xcodebuild invocation with those flags (evidence
  phase2-h14-appstore-build.log). The script itself is T7-owned; wiring the
  flags into it belongs to a future build-infra task.
- The precompiled rust-std members inside HerdrCore.a still make host `nm`
  exit nonzero ("Unknown attribute kind (105)", LLVM 22 producer vs Apple
  LLVM 21 reader). ld links them fine; build-herdr-core.sh verify() ignores
  nm's exit on unreadable members and matches the workspace-crate symbols.
- herdr_client_receive's error detail is borrowed until the client's next
  call (client-owned) — Swift copies it immediately; C callers must do the
  same. Documented in HerdrCore.h doc comments and the crate-level docs.
- The fuzz smoke asserts bounded PENDING-INBOUND (<= fed bytes) rather than
  total RSS; a true RSS bound check belongs to T20's hardening pass with
  the real transport attached.

## H15 (2026-09-10)
- Pre-existing deterministic failures (NOT caused by H15, which touched only Herdr/SSH files): CoderNativeStartupAcceptanceTests (2 cases: startup script connection gating), CoderNativeRebuildAcceptanceTests (rebuild stream/replacement UUID), CoderNativeControlRecoveryTests (NSURLError -1004 despite healthy fixtures stub — test likely targets a differently-addressed server). Reproduce identically after fixtures refresh. Full regression: 355 executed, 15 skipped, 335 passed, 8 failures all in these suites.
- scripts/test-core.sh ONLY_TESTING limitation: single comma-joined -only-testing flag matches nothing; run one suite per invocation.
- H15 acceptance criterion 2 (full Swift<->Rust handshake against real herdr-core binary) is DEFERRED to T14 verification — mock-bridge.py covers the protocol contract meanwhile.

## Open — T16 FFI surface/activation gap (2026-09-10)

- The committed herdr-ios-ffi C ABI cannot hand a pane surface to Swift:
  every PaneSurface server frame surfaces as HERDR_CODE_SURFACE_REJECTED
  and herdr_client_surface stays empty, because the shell's endpoint
  projection is never activated (ClientShellState.active stays Home;
  activate_endpoint_projection is pub(crate) to herdr-client-core, and the
  only public path, complete_activation + PendingEndpointActivation, is
  not exposed through the ABI). Probe: .sisyphus/evidence/phase2-h16-ffi-surface-probe.log.
- Consequences: T16 renders pane contents only via the fixture JSON in
  UI tests (byte-identical to the accessor's future output); live
  sessions run snapshot-only with a typed surfaceUnavailable note
  (surfaceRejected treated non-fatal: the frame is dropped whole, client
  stays Online). T17 semantic input is blocked the same way
  (inputFrozen until activation) AND there is no resize entry point in
  the ABI — resize currently only reaches the next connection's hello.
- Routing hint: a small additive FFI surface (activate-projection /
  complete-activation + resize) owned by a task allowed to touch
  Vendor/herdr resolves all three.

## Open — T16 Phase B herdr server fixture blocked-environment (2026-09-10)

- herdr v0.9.0 host build requires EXACTLY zig 0.15.x (requireZig enforces
  major.minor equality) for the vendored libghostty-vt; zig 0.15.2 cannot
  link even a hello-world on this macOS 26 host (undefined _abort/_bzero/
  _sigaction — libSystem not linked). Full details + three unblock options:
  .sisyphus/evidence/phase2-h16-server-fixture.md.
- Therefore the live-server UI test, live soak, and T15 criterion 2
  (full Swift->Rust handshake against a real herdr server) remain
  unexecuted in this environment; Phase A replay evidence stands in.
