# Learnings — bicterm-phase2-coder-ssh

Conventions, patterns, and successful approaches discovered during work on this plan.

_Auto-scaffolded by /start-work. Append new entries below - never overwrite._

---

## T10 (2026-09-07) — lifecycle, auth-loss taxonomy, usage heartbeat

- `ONLY_TESTING` (and xcodebuild `-only-testing:`) takes ONE suite per run;
  comma-separated identifiers silently execute 0 tests. Run suites
  individually.
- T9's `testRegistryHasNoCoderNetImports` greps every BicTermCore source for
  C-bridge symbol names (`CoderNetStart`, …) — even in doc comments. Names
  like that fail the audit; word docs around them without the literal tokens.
- SourceKit/LSP diagnostics on SPM package sources in this repo are pure
  noise (same-module types reported unresolved in every file, including
  committed ones). `xcodebuild` is the authoritative typecheck.
- Cancellation-aware test doubles: registration of a `CheckedContinuation`
  must happen SYNCHRONOUSly inside the continuation body — Task-hopping back
  onto an actor races `onCancel` and leaks parked tasks. The repo's
  lock-confined pattern (`AgentSessionBook`, `ScriptTunnel`: NSLock + never
  straddle an await) is the deterministic shape.
- A registry-driven `.suspended` transition for a `.nativeRoaming` transport
  must call the transport's `suspend()` too: registry state and transport
  phase are distinct machines, and `resume()` guards on the transport phase
  (a skipped suspend turns the next resume into `.channelDenied`).
- AsyncStream-fed negative assertions ("never surfaces X"): a fixed ~200ms
  settle window is deterministic for purely local actor hops; pair it with
  the positive-path twin in the same suite.
- XCTest: never `await` inside `XCTAssertEqual`/`XCTAssertTrue` autoclosures;
  bind a local first. Same for `XCTUnwrap(await …)`.
- Registry+factory wiring cycles (registry ← factory ← collaborator ←
  registry) resolve with an `attach(registry:)` post-construction hook on the
  middle component; `@Sendable` closures may not capture not-yet-created
  mutable vars (Swift 6 strict), so don't try slot-box tricks.
- `scripts/test-core.sh` already tees its own evidence log repo-local;
  redirecting its stdout anywhere (especially off-repo scratch) breaks the
  repo-local-writes rule — just read the evidence log.

## T11 (2026-09-08) — agent picker, start policy, diagnostics

- Persist an explicit Coder agent UUID only after a user pick when a build
  exposes multiple connected agents. Revalidation must clear a vanished UUID
  and require another choice rather than silently selecting a replacement.
- A stopped-workspace start policy belongs in per-connection protocol options
  and defaults OFF. The connect flow must resolve dormancy and template
  parameters before issuing its single explicit start POST.
- SwiftUI `GridRow` accessibility identifiers are more reliable in XCUI when
  applied to the row's value `Text`, not the `GridRow` container.
- A one-poll transient fixture is too short for XCUI's roughly one-second
  existence cadence. Hold the DEBUG-only pending state across two detail reads
  so all layered progress rows can be observed without slowing production.
- `CoderLifecycleCoordinator` currently consumes `networkPathChanged`
  internally and exposes no app observation callback. Production path
  diagnostics therefore need a future T10-owned event tap; T11 must not create
  a competing `AsyncStream` consumer or modify `BicTermCore`/`CoderTunnel`.

## T11 repair (2026-09-08) — production path-event routing

- Keep `CoderLifecycleCoordinator` as the sole production event-stream
  consumer. Its observation callback must run only after handle lookup and
  credential-generation validation so late events cannot mutate replacement
  sessions.
- The existing Go log callback can carry machine-readable JSON envelopes in
  addition to human logs. Parsing only recognized `codernet_event` lines in
  `CoderTunnel` preserves App Store isolation while exposing production path
  changes to the coordinator.
- Restored terminal windows can survive XCUI relaunches without a live session
  descriptor. A DEBUG-only launch argument that prefers the connection list in
  that state makes persistence tests deterministic without changing live-scene
  precedence or release behavior.
- On iPad, dismiss the software keyboard before opening Coder pickers and do
  not synthesize fallback drags when no keyboard exists; otherwise the drag can
  dismiss or reposition the editor instead of revealing the intended control.
- Exact-state XCTest evidence should capture `app.windows.firstMatch` after the
  assertions. On iPad, expand the medium diagnostics sheet by dragging its
  handle to the large detent before capture; swiping a partially clipped value
  does not reliably move or expand the sheet.
- The DEBUG pending-start fixture needs six detail reads, not two, to keep the
  layered progress view settled through XCTest's assertion and screenshot
  cadence. This does not change production polling.
- App Store symbol audits must distinguish pure-Swift `CoderNetEvent` model
  names from forbidden Go bridge/SDK symbols. Audit the exact bridge entry
  points plus `workspacesdk`/`codersdk`, and retain the default flavor as a
  positive control.

## T12 continuation (2026-09-08) — reproducible UI causes

- The iPhone Coder server picker overlapped the keyboard accessory toolbar
  because changing protocol retained name-field focus. Clear that focus on
  protocol change; the protected reauthentication test then passes unchanged.
- Plain SwiftUI buttons with Spacer-heavy labels need a contentShape for a
  full-row hit target. CoderServerRow's center tap failed on iPad until fixed.
- A restored terminal window without a usable snapshot must not strand the
  user on an inert placeholder. Resolve first, then offer the connection list;
  keep DEBUG session bootstrap once-per-process across restored windows.
- Preserve full-run xcresults with explicit repository-local resultBundlePath.
  Xcode's rolling DerivedData/Logs/Test results can disappear after later runs.
- The iPad field replacement helper silently continues if Select All is absent.
  Recorded port 1222222 proves this is not a transport failure. Command-A,
  triple-tap, and end-coordinate plus deletes did not provide a reliable fix;
  unsuccessful changes were restored and a failing behavior test retained.

## T12 focused UI closure (2026-09-09)

- The remaining iPad port failure was a production keyboard choice issue:
  numberPad appeared as a popover with PopoverDismissRegion, making the
  focused underlying field non-hittable. numbersAndPunctuation on iPad
  fixes both replacement and password-port flows without changing the helper.
- Agent picker choice rows need their own contentShape(Rectangle()). The
  failure hierarchy stayed on Select Agent after the center tap: persistence
  was not being lost; the selection action was never reached.
- Use supportsMultipleWindows, not horizontalSizeClass, for new-connection
  routing. Both main list and terminal New Connection now open distinct iPad
  windows; explicit existing-session selection still switches in place.
- Bootstatus -b must precede clean uninstall. The corrected iPhone trust
  setup passed isolated and in the full suite without trust-policy changes.
- Scoped closure: 63 UI tests on each destination, zero failures, existing
  platform skips only; both independent visual reviewers inspected 12/12
  images and returned PASS. See phase2-g12-ui-acceptance.md.
- Pin UI source/test hashes before long simulator runs and verify them again
  afterward. Regenerate captures if they predate the latest source timestamps;
  validate PNG signatures/dimensions/freshness before independent review.

## T12 raw/DERP checkpoint (2026-09-09)

- SSH stdin EOF must not trigger whole-proxy teardown. Drain stdout, stderr
  extended data and exit-status requests before closing the channel; the
  new EOF regression exposed lost output and absent remote status.
- A DERP audit proxy must be the raw client's base URL (7081), not merely
  the server access URL while the client still targets 7080. Empty upgrade
  ledgers are not evidence of transport success.
- Treat expected SIGTERM child status during fixture cleanup explicitly so
  the default native deployment restoration step still runs.
- Raw tests separately report per-case acceptance and aggregate failure;
  A31's stdout-failure timeout is not erased by other passing raw cases.

## T12 A31 closure (2026-09-09)

- x/crypto forwards EOW channel requests without filtering, but OpenSSH's
  default compatibility match suppressed the request for SSH-2.0-Go: DEBUG3
  logged send eow without packet type 98, then continued window adjustments.
- The explicitly labelled OpenSSH_compat_BicTerm software identification
  enables the client's OpenSSH* compatibility path without claiming a real
  OpenSSH release. Received eow@openssh.com and direct copy-write failures
  must close the owned upstream connection so all relays unblock.
- The banner-only toggle reproduced the native timeout and restored success;
  both direct and relay-only A31 cases pass with normal LogLevel=ERROR.

## T12 Batch B authentication/permission (2026-09-09)

- Native Swift invalid-token coverage can use the real SystemCoderRequestLoader
  with a request ledger and a tunnel that fails if touched: assert [401] and
  authRequired, proving no retry, no tunnel allocation and no credential mutation.
- A valid distinct native user receives authorization-hidden 404 for another
  owner's agent connection while the owner receives 200 for the same path.
  Verify users/me 200 for the outsider first so invalid credentials cannot
  masquerade as an authorization test. Delete the temporary user afterward.

## T12 native agent selection (2026-09-09)

- Coder's Terraform association parser treats a dynamic map containing both
  agents as dependencies on both. Per-agent script resources must reference
  their specific coder_agent directly; otherwise build completion fails on
  duplicate agent names. Keep the shared shell writer free of agent references.
- coder update has no --yes flag in v2.36.4. It stops/restarts an outdated
  running workspace, creating fresh agent IDs. Restart the owned host agent
  processes afterward so they read regenerated tokens instead of retrying 401.
- Core transport previously ignored saved agent options. Resolve exact names
  or UUIDs only within the current build; a supplied UUID takes precedence and
  never falls back to a name. Native agent-specific environment markers prove
  main/sidecar routing without echo-based false positives.

## T12 native start and response loss (2026-09-09)

- Start response-loss coverage should forward the real POST first, observe
  201, then throw at the request-loader boundary. Assert the next request is
  the workspace GET and the entire run contains only one POST.
- Native agents regenerated by a start build need a host-side watcher in
  acceptance tests. Watch script hashes, not secret values; publish scripts
  atomically and launch only changed scripts under repository-local homes.
- The explicit-start and lost-response tests both reached a new connected,
  ready agent with exactly one accepted mutation. The start-disabled Core
  path recorded GET/GET and zero mutation requests.

## T12 native startup-policy closure (2026-09-09)

- Agent connection status is not script readiness. Decode scripts and
  lifecycle_state in Core, enforce start_blocks_login on the selected agent,
  and refuse start_error/start_timeout instead of silently connecting.
- A held-script release marker gives deterministic native proof: blocking
  connect stays pending; nonblocking connect finishes while completion is
  absent. Exercise both already-running resolution and explicit-start paths.
- Keep the startup wait monotonic and cancellation-aware. Re-resolve the
  current build each poll, so an old explicit UUID cannot redirect silently.
- Selector parsing moved into CoderAgentSelection to keep CoderTransport
  below its 250-line ceiling. No UI view source needed modification.

## T12 gate approval (2026-09-09) — Atlas

- User approved the Coder phase gate: NOT-LOCAL dispositions accepted,
  SFTP/port-forwarding is a possible future want (backlog note, not planned),
  App Store isolation and iPad multi-window behavior accepted.
- Model routing preference: avoid gpt-6-astra unless necessary (slow);
  prefer glm/kimi fast lanes. All models reportedly available again.
- Upstream pin updated: herdr v0.9.0 multi-machine
  (b99002ac99b09e00b4ca692436cb15a6b0d676f1). Updated
  HERDR_IOS_INTEGRATION.md adds multi-machine scope (endpoint catalog/
  registry, activation transaction, machine-qualified identity §3.5-3.6,
   §6.4-6.5) that Herdr tasks must now include.

## T13 preflight (2026-09-09)

- The local-cache preamble redirects CARGO_HOME but not RUSTUP_HOME.
  The active Rust 1.93.0 compiler resolves under /Users/richard/.rustup;
  redirecting Cargo caches alone does not contain rustup target installation.
- Updated integration scope requires multi-machine activation through the
  post-commit presentation fence, not merely selecting another connection.
- Task 13's commit-template line still names 702aa1e; use the explicit
  task request's b99002ac subject without editing the plan.

## T13 repository-local provisioning (2026-09-09)

Commands executed from the repository root:

```sh
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
mkdir -p "$RUSTUP_HOME"
rustup toolchain install stable --profile minimal --no-self-update
rustup target add --toolchain stable aarch64-apple-ios aarch64-apple-ios-sim
rustup target list --installed --toolchain stable
rustc +stable --version
cargo +stable --version
cargo +stable install --locked --root "$PWD/.build-artifacts/tools" cargo-deny
"$PWD/.build-artifacts/tools/bin/cargo-deny" --version
```

- All commands succeeded. Rust 1.98.1 (48a229cea 2026-09-01), Cargo 1.98.1
  (797e8a9bc 2026-08-05), cargo-deny 0.20.2. Installed targets are
  aarch64-apple-darwin, aarch64-apple-ios, and aarch64-apple-ios-sim.
- Keep the RUSTUP_HOME export in every Rust shell; the shared script still
  redirects only Cargo caches, not rustup. `.build-artifacts/` is gitignored.
- Upstream checkout verified at b99002ac99b09e00b4ca692436cb15a6b0d676f1.
  Archive SHA256: 6026052a4e11914fa7bc1d4080f44130dfa2640b02851029f6712613e6062beb.
  Use an absolute repo-local archive output with `git -C`; the plan's
  relative output would resolve under the upstream checkout.
- Isolated upstream health module: 3 host tests passed, both iOS builds
  passed. This proves provisioning, not the full client extraction.
- Activation's presentation completion crosses into shell_runtime.rs;
  moving activation.rs alone does not preserve the full input-unfreeze fence.
- Upstream CONTRIBUTING.md routes feature proposals to Discussions, not
  feature-request issues. A local unsubmitted draft is retained.

## T13 extraction verification completed

- The 33/95 dependency failures were resolved through small foundational type
  extraction and removal of desktop conversion/I/O paths, not by importing
  the whole desktop shell or substituting no-op runtime services.
- `Vendor/herdr` now contains herdr-protocol and herdr-client-core. All 22
  upstream activation tests survive the neutral projection-store adaptation,
  including rollback, rapid successor switches and presentation fences.
- Protocol: 65 tests; core: 57 tests; total 122 passed, zero ignored/failed.
  43 committed golden frames cover all 21 client and 21 server variants plus
  the stable JSON snapshot carrier. Capture uses the original encode path.
- `bash Vendor/herdr/check.sh` passes host tests, macOS/device/simulator builds,
  production target-resolved cargo-deny, negative license-policy checks and
  the excluded-runtime import scan. Logs: `.sisyphus/evidence/phase2-h13-*`.
- Each iOS production graph has 25 packages (2 local + 23 external), including
  build dependencies. Explicit license entries include Unicode-3.0 and
  Unlicense, not just Apache/MIT. JSON inventory preserves AND/OR expressions.
- Red/green regressions protect metadata/surface revision coherence before
  input, conflicting duplicate surfaces, and optional future response fields.
- Re-running both extraction scripts leaves committed Rust code unchanged;
  they check both the pin and a pristine upstream worktree before copying.
- Native rendering, gestures/selection/keymaps, replay execution and SSH I/O
  remain caller responsibilities. Follow `Vendor/herdr/README.md`, especially
  the final presentation-ready gate and per-viewer identity scope.

## T14 (2026-09-10) — HerdrCore.xcframework + panic-safe C ABI

- One header-carrying xcframework per app build, maximum: ProcessXCFramework
  flattens every xcframework's module.modulemap into the SHARED per-config
  `Products/.../include/` dir, so CoderNet.xcframework + a second
  header-carrying framework collide ("Multiple commands produce
  include/module.modulemap"). HerdrCore.xcframework therefore ships
  headerless; a HerdrCoreC clang-module target (stub.c + committed
  cbindgen-generated HerdrCore.h, drift-checked by the build script) hosts
  the module.
- rustc 1.98.1 (LLVM 22) staticlibs must set `lto = false` for Apple
  artifacts: Xcode 26's nm/ld readers are LLVM 21 and reject the archive
  ("Unknown attribute kind (105)"). Precompiled rust-std rlib members still
  carry bitcode sections nm cannot read — ignore nm's nonzero exit on those
  members; ld links them fine.
- `dsymutil` cannot read a static archive's debug map. To archive dSYMs for
  a Rust .a, link it into a throwaway stub dylib that references
  `herdr_client_create`, run dsymutil on THAT, and delete the stub.
- xcodegen config-qualified settings (settings.configs.X.OTHER_LDFLAGS)
  shadow the same key in settings.base at the target level — $(inherited)
  does NOT recover base. Put every needed flag in each config block
  explicitly (this bit the `-u _herdr_client_create` anchor: AppStore
  inherited it from base, Debug/Release lost it to the CoderTunnel block).
- Debug app binaries are thin launchers under Xcode 26 (ENABLE_DEBUG_DYLIB):
  audit symbols in BicTerm.debug.dylib, not BicTerm, or the sweep reports
  false zeros.
- Swift imports cbindgen `#define` integer constants as Int32; converting at
  the mapping boundary (UInt32(HERDR_KEY_X)) keeps the FFI struct fields
  typed per the header.
- `destroy()` on the FFI-wrapping actor is nonisolated on purpose (single
  destroy per ownership rule, after last in-flight call); deinit provides the
  same release if never called. Actor handle storage is
  `nonisolated(unsafe)` with the exclusivity argument documented.
- cbindgen 0.29 takes the WORKSPACE DIRECTORY as its positional input (a
  Cargo.toml path is parsed as Rust source) plus --crate for member
  selection. Opaque C handles need `_private: [u8; 0]` ZST + pointer cast in
  the ABI layer; a pub(crate) Rust-typed field makes cbindgen emit a broken
  forward decl.
- Host FFI tests share the process-global allocation ledger: serialize the
  test binary with a static Mutex or parallel tests fail the balance
  assertion on each other's in-flight clients.
- `xcodebuild -only-testing:` needs the full `Target/Suite` path for
  hostless framework test bundles.

## H15 herdr non-PTY exec transport (2026-09-10)
- Swift 6 forbids NSLock.lock/unlock directly in async methods (`unavailable from asynchronous contexts`). Pattern: do the lock-confined critical section in a SYNC helper (e.g. `claimClose()` returning the claimed task) and await session.close() outside it. Never let locked state straddle an await.
- Mock-bridge protocol: the client's FIRST frame is consumed as the hello (payload ignored, never echoed); only subsequent frames are echoed. Every new transport test must write a dedicated hello frame first or subtract it from expectations. Byte-count assertion diffs were exactly one frame (11 B and 5 B), which pinpointed the modeling bug, not a transport drop.
- Fixture shim `mock-herdr` resolves `mock-bridge.py` via `$(dirname "$0")` — it is only relocatable TOGETHER with its sibling script. The hostile-path test must copy both into the hostile dir; otherwise python3 exits status 2 ("can't open file") with zero output.
- `FileManager.removeItem` throws NSFileNoSuchFileError (Code=4) on a missing path — guard "delete-if-exists" cleanup with `fileExists`, never `try?` (would mask real permission errors).
- Swift string literals have no `\x00`/`\xff` escapes; build raw bytes with `Data("HELLO".utf8) + Data([0x00, 0xFF])` (note `"\u{FF}"` is 2 UTF-8 bytes, not one).
- xcodebuild needs one `-only-testing:` flag per suite; a comma-separated value in a single flag silently matches 0 tests (scripts/test-core.sh forwards ONE flag).
- H15 follow-up: shared fixed-name fixture dirs fail under full-gate concurrency (copyItem EEXIST/516 on the unguarded sibling copy). Root fix = per-run UUID dir + defer teardown, never shared Fixtures/run paths.

## T16 (2026-09-10) — herdr session model + native workspace UI

- `.accessibilityIdentifier` on a SwiftUI CONTAINER (ScrollView/ZStack/
  applied over a child view) SPREADS to every descendant accessibility
  element and can override the children's own identifiers. Per-element
  identifiers + firstMatch queries are the reliable shape; container-level
  identifiers made 3 of 4 pane overlays invisible to XCUI and produced
  "multiple matching elements" failures.
- Bare stroke `Rectangle`s carrying accessibilityLabel/identifier are
  PRUNED by the AX runtime unless they have traits; an invisible
  `Color.clear` base inside the same ZStack materializes reliably
  (`.accessibilityElement(children: .ignore)` + label + traits).
- `openWindow` called during scene STARTUP (from `.task` at launch)
  creates window scenes that never surface on iPad — iOS 26 sim observed.
  Bootstrapping from the first `.active` scenePhase transition (with a
  once-guard, SessionUITestDriver pattern) works.
- One source of truth for singletons: a `@State` instance in the App plus
  a `.shared` static used by presenters = two registries; iPad windows
  looked up the empty one and showed the fallback. iPhone covers worked,
  masking the split.
- herdr cell colors are tagged u32s: 0x00 named(0..=16), 0x01 xterm index,
  0x02 RGB (upstream color_to_u32); modifier bits are ratatui's (bold 1<<0,
  italic 1<<2, underline 1<<3, reversed 1<<6). Canvas glyph size must fit
  BOTH cell axes (monospace advance ≈ 0.6em) or 80-column phone-width
  grids garble from horizontal overflow.
- The committed FFI (herdr-ios-ffi) cannot commit a PaneSurface:
  ClientShellState.active stays Home (endpoint projection never activated;
  activate_endpoint_projection is pub(crate) in herdr-client-core).
  Empirical probe committed as phase2-h16-ffi-surface-probe.log. The same
  gap keeps semantic input frozen (unfreeze lives in complete_activation) —
  T17 hits it too; fix belongs in a Vendor-touching FFI task.
- xcodebuild UI-test screenshots exported via `xcresulttool export
  attachments` come out under raw UUIDs with a manifest; names inside the
  manifest may already carry `_0_<UUID>` dedup suffixes when tests reuse
  attachment names — normalize before committing evidence.
