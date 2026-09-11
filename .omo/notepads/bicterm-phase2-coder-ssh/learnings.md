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

## FFI activation driving (phase 2, herdr-ios-ffi)

- `PendingEndpointActivation::begin` needs a shell projection WITH a snapshot (`endpoint_lease` -> `endpoint_snapshot_identity`), so a begin attempt at welcome ALWAYS fails preflight with zero side effects (target lease is resolved before `freeze_input`/any send). The transaction can only arm on the first accepted snapshot — begin is attempted at welcome (per plan) and retried inside `apply_snapshot` while idle; each failed attempt burns one serial, which is harmless (serials must be unique, not contiguous).
- Guard the retry with `shell.active_endpoint() == endpoint`: without it, every post-commit snapshot restarts a transaction (freeze_input + lifecycle churn) and the client never settles. `endpoint_is_active` is `pub(crate)` in core and unreachable from the FFI crate; `active_endpoint()` is the public equivalent.
- `progress()` only reaches `Ready` after a `ClientShellEndpointResponseChunk` carrying `ResponseResult::ClientShellSurfaceSet { active: true, projection_revision }` (sets `acknowledged_revision`) AND a snapshot+surface pair coherent at that revision and geometry. A welcome+snapshot+surface sequence alone never commits — the ack chunk is what closes the loop; `herdr_client_surface` stays empty without it.
- The completion path (`complete_activation`) itself queues a presentation-sync request AFTER committing the surface, so a post-commit outbound drain is expected to find frames; the surface IS committed (`set_pane_surface`) before presentation sync settles. Input stays frozen until the presentation-effects fence clears, which the FFI does not yet drive (EndpointControl `PRESENTATION_EFFECTS_SYNC_KIND` arm is future work).
- Golden surface fixture (server-10.bin) does NOT correlate with the golden snapshot (boot-v1/rev-7/80x24 vs "boot"/rev-3/1x1); an activation test must encode its own frames via `herdr_protocol::write_message` and recover the actual `client-shell-surface:{serial}:on` request id from the drained outbound frames (the serial depends on failed begin attempts).
- `ClientShellResize` carries 4 fields (cell dims, surface_size, pixel_mouse), not just surface_size — the FFI client stores the create-time geometry context to rebuild resizes faithfully.
- check.sh enforces <=250 pure LOC per src file (blank+comment lines excluded); abi.rs was already at 236, so adding `herdr_client_resize` forced a split (lifecycle/IO in abi.rs, read-only accessors/telemetry in abi_query.rs). Same for the activation methods (client_activation.rs). rustfmt wraps long extern signatures to ~5 lines, budget accordingly.
- build-herdr-core.sh fails BY DESIGN on cbindgen header drift, updates the committed HerdrCoreC/include/HerdrCore.h, and asks for a re-run; the header change belongs in the same commit as the ABI addition.

## T16 surface-commit repair (2026-09-10) — FFI activation fix follow-up

- The FFI activation transaction (b5c1d98) needs a SERVER ROUND-TRIP
  before a surface commits: after the first snapshot the client sends
  resize + `client_shell.surface.set` request + focus baseline, and the
  surface only commits once a `ClientShellEndpointResponseChunk`
  acknowledges the request id with
  `{"result":{"type":"client_shell_surface_set","active":true,
  "projection_revision":<rev>}}` AND a geometry-matching surface arrives.
- The activation request id is DETERMINISTIC but NOT "serial 1": the
  welcome-time `begin_activation_if_idle` attempt consumes serial 1 and
  fails preflight (no lease without a snapshot), so the snapshot-time
  transaction is serial 2 → "client-shell-surface:2:on". Fixtures must
  correlate against that (Fixtures/herdr/golden/surface-ack-2x2.bin).
- The acknowledged `projection_revision` must equal BOTH the snapshot
  revision and the surface's `projection_revision` (coherence check).
- Swift-side consequence: the inbound pump now drains+writes outbound
  after EVERY receive — activation/control frames queue mid-session, not
  just the connect-time hello. A connect-only flush would strand the
  activation request on a live server.
- `debugInjectSurface` (test-only surface injection) became dead code
  once the ack frame completed the transaction and was removed; the UI
  tests now render pane cells from the REAL committed FFI surface on
  both canonical simulators.
- `surfaceUnavailable` remains in the model as the typed note for
  genuine out-of-lease rejections (stale evidence / revision conflicts /
  wrong boot — doc §7 coherence); it is no longer exercised by the
  happy-path fixtures.
- The gen-crate probe (`--probe --golden <dir> --fixtures <dir>`) now
  drains and decodes every outbound frame after each feed — printing the
  actual wire round-trip is the fastest way to pin fixture correlation.

## Fence completion + clipboard FFI (phase 2, herdr-ios-ffi wave 2)

- The presentation fence needs TWO commits and a re-sent evidence pair: complete() in ActivatingTarget commits the surface but restarts evidence EMPTY for SynchronizingPresentation (and again for AwaitingPresentationEffects). Full unfreeze sequence: ack(:on) → surface (commit 1) → ack(:presentation-sync) → snapshot AGAIN → surface AGAIN (commit 2 + fence opens) → EndpointControl(ready, token). Skipping the re-sent snapshot+surface leaves progress Pending forever — evidence.snapshot_revision must equal surface.projection_revision for coherence.
- The fence token is "{epoch}:{generation}:{boot_id}" (e.g. "2:1:boot-v1") and is echoed back as the ready control's data. Extract it from the drained outbound EndpointControl(kind=endpoint.presentation.sync.v1) instead of hardcoding — epoch shifts if begin-attempt counting changes.
- try_complete_activation must keep `self.pending` on AwaitingPresentationSync/AwaitingPresentationEffects (and on Err); only Activated/RestoredSource are terminal and unfreeze input. Dropping pending at commit 1 froze input permanently — that was the b5c1d98 gap this wave closed.
- Input staleness: send_pane_input rejects StaleTarget when the committed SURFACE (not the snapshot) lacks the pane id. Test surfaces must carry `panes: vec![PaneSurfacePane { pane_id: "w1:p1", ... }]` or input returns HERDR_CODE_INPUT_STALE_TARGET (12) even after unfreeze.
- Clipboard cap: MAX_CLIPBOARD_IMAGE_PAYLOAD (16 MiB, herdr_protocol::input) applies to OSC 52 TEXT too. Check `len.div_ceil(4)*3 > cap` BEFORE decoding (a >16MiB payload allocates nothing); drop non-fatally with the new HERDR_CODE_CLIPBOARD_DROPPED (16) — receive returns the structured detail, the frame is consumed, buffered frames survive, phase stays Online.
- Workspace had NO base64 anywhere; added base64 = "0.22" to herdr-ios-ffi (MIT OR Apache-2.0, zero transitive deps — passes deny.toml allowlist and multiple-versions=deny). Ledger row in MODIFICATIONS.md (new "iOS FFI crate dependencies" section), LICENSE_INVENTORY.json regenerates via check.sh.
- Oversize-clipboard test needs max_frame_size lifted to 24 MiB in the client config (default MAX_FRAME_SIZE is 2 MiB; ceiling is MAX_GRAPHICS_FRAME_SIZE 32 MiB) or the frame itself fails as a protocol violation before the drop path runs.
- herdr_client_receive's len==0-null-bytes convention is a no-op OK; for send_clipboard_image len==0 is INVALID_ARGUMENT instead (caller error, not wire no-op).
- Combined commit rationale: cbindgen emits lib.rs constants (HERDR_CODE_CLIPBOARD_DROPPED appears in the header), and client.rs/tests/ffi.rs carry hunks from both the fence fix and the clipboard feature — a two-commit split requires hunk surgery and intermediate header states; the task explicitly allows one combined commit.

## Herdr semantic input (phase 2, task 17)

- XCUI `typeText` no-ops against the herdr replay scene just like `typeKey`: the field is the key-window scene responder with a live RTI session (device log proves it) and zero synthesized events ever arrive. Don't fight XCTest — the `--uitest-hwkeys` injector now carries text too: `text:<string>` delivers one `insertText` per grapheme (soft-keyboard granularity) into the registered field, and `await:echo:<needle>` polls the mirrored input echo (`HerdrWorkspaceUITest.currentInputEcho`) so commits can be ordered after a tap retarget.
- SwiftUI views placed with `.position()` report the CONTAINER's accessibility frame (all four panes claimed the full pane area — XCUI tapping "p1" hit p4's corner, and VoiceOver users would hit the same defect). Place panes layout-wise (padding inside a `ZStack(alignment: .topLeading)`) so AX frames and hit tests are real.
- Feedback strips in the layout flow compress the pane area, and every compression reads as a grid change → resize-echo feedback storm (rows 15→14→13→12→6 in one run). Overlay the strips (`allowsHitTesting(false)`) and put `.ignoresSafeArea(.keyboard)` on the workspace root — the remote owns the grid; the keyboard must never read as geometry.
- `becomeFirstResponder` in `didMoveToWindow` silently fails while the window isn't key yet; re-assert on `UIWindow.didBecomeKeyNotification`. Extract the window from the notification OUTSIDE `MainActor.assumeIsolated` (Swift 6 sending error on non-Sendable `Notification` otherwise) and remove the token from an `isolated deinit`.
- UIKit traps when `super.presses*` receives a nil `UIPressesEvent` — the injector passes nil, so every super call is guarded by `event != nil`.
- The fence's evidence resend keeps `surfaceRevision == 1`; `debugAppliedChunks >= <script count>` is the fence-complete signal, not the revision number.
- Echo assertions must include the echo format's closing punctuation — `界"→w1:p2` matches, `界→w1:p2` never does (the payload's closing quote sits between). A needle that skips format punctuation burns a full debug cycle before you notice the echo was right all along.
- `scripts/fixtures-up.sh` chmods `$KEYS/host_keys/*` but the sshd host keys live in `$SSHD_DIR/host_keys/` — the glob never matches, and git checkouts restore 0644, so sshd dies with "no hostkeys available" on a fresh checkout. Local repair: `chmod 600 Fixtures/sshd/host_keys/* Fixtures/sshd/host_key_alt/*` (permission bits only, no repo diff).
- Focus retarget has no post-activation FFI entry point (upstream `focus_endpoint_target` at client/shell/actions.rs:462 was never extracted into the FFI) — the app routes input by pane_id at enqueue time instead. If focus retargets ever need to cross the wire, that function is the extraction candidate.
- TerminalUITests fail wholesale on the iPad simulator at the `-uitest-terminal-preview` gate ("No connections yet" — the launch flag never engages) while passing 6/6 on iPhone with the same build; gate files unmodified, and launch-arg-gated herdr tests pass on the same iPad sim. Pre-existing/environmental (last green iPad evidence: t12-ipad-nonhardware.log); root cause somewhere in T13–T16 or the sim, not task 17.

## iPad scene-session persistence (phase 2, task 17 follow-up — corrects the misattributed bullet above)

- iPadOS persists scene sessions across app launches AND hard simulator shutdowns: a herdr window opened by one UI test suite is restored in later suites. Every WindowGroup must mirror the `-uitest-terminal-preview` gate — the T16 herdr group lacked it, and HerdrWindowRoot's nil-state connection list shadowed the preview, timing out all 6 TerminalUITests (40 s each) whenever a herdr suite ran first on the same iPad sim. Fixed by gating the herdr group; verified with the contaminating ordering (herdr suites → TerminalUITests 6/6 without uninstall → herdr suites green).
- The app's real bundle ID is `com.bicterm.app` (not com.bicterm.BicTerm); `simctl uninstall` against a wrong ID silently no-ops, which can masquerade as "clean install didn't help".
- Discriminator for this family: process argv carries the flag + installed binary is the correct gated Debug build + the wrong root view renders = a restored scene session from an ungated WindowGroup, not an argument-delivery or environment problem. Third iPad multi-scene gotcha after "openWindow during scene startup never surfaces" and the singleton split-brain.

## Herdr clipboard (phase 2, task 18)

- Outbound byte budget blocks max-size clipboard images: the FFI default 4 MiB silently rejects any frame >= 4 MiB (e.g. a 16 MiB clipboard image) as "endpoint byte budget exceeded" — the error surfaces through `send_clipboard_image` / outbound queue, not through the 16 MiB protocol cap. Fix at the model layer (`HerdrSessionModel.connect`) by lifting `HerdrClientConfig.outboundByteLimit` to 24 MiB (16 MiB image + frame envelope + queue headroom); the FFI exposes the field on `herdr_client_config`. Without this, `testClipboardImageAtCapMinusOneIsAccepted` and `AtCap` fail despite being under the 16 MiB protocol cap.

- `MAX_CLIPBOARD_IMAGE_PAYLOAD = 16 MiB` lives in `herdr-protocol/src/input.rs:17` but is NOT exported over the C ABI (`Vendor/herdr/herdr-ios-ffi/src/lib.rs` omits it). The app hardcodes `HerdrClipboard.maxImagePayloadBytes = 16 * 1024 * 1024` as a UX pre-check; the FFI is the authoritative backstop on send (accept/reject at the cap). Document the gap so a protocol-side change fails closed instead of silently drifting — and so we know to bump the app constant if upstream ever moves the cap.

- No per-host KV settings store existed for herdr endpoints: `ProtocolOptions` is per-`Connection`, but herdr endpoints aren't `Connection`s. Decision: `HerdrClipboardSettings` is UserDefaults-backed, key `herdr.clipboard.autocopy.<endpointRaw>`, injectable suite (tests pass ephemeral UUID suites). UITestSupport resets the four replay endpoints to OFF at launch so every UI run starts from a deterministic privacy state.

- UIPasteControl XCUI tap delivery is not exercised on the iOS 18 simulator this task targets: neither the bare system-delivery path (`UIPasteControl` + `paste(_:)` override on the first responder) nor the `addAction(UIAction { primaryActionTriggered })` + manual-read path delivers paste under XCUI tap. The production gesture works in-app; the XCUI limitation is the blocker for gesture-level UI tests. Resolution: move gesture-level coverage into the unit suite (cmd+v classification, paste-text vector via `model.pasteText`, large-paste classify, EXIF strip at the model boundary); the UI suite keeps the banner + Copy + AutoCopy buttons (real `Button` taps, not `UIPasteControl`). Document the scope cut in the test file header.

- The swift-frontend "Found ownership error?!" SIL verifier bug: a typed `catch let error as HerdrClientError { ... throw error }` inside the `for try await chunk in transport.inboundBytes()` loop in `runInboundPump` crashes the Swift frontend with a SIL ownership error. Workaround: plain `catch { ... }` + `await model?.handleClientError(...)` + `return` outside the loop, with the clipboard-drop non-fatal path using an explicit `if case .clipboardDropped(let detail) = error { ... continue }` inside the inner do-block. The typed-rethrow pattern is the canonical Swift idiom and SHOULD work; this is a compiler bug that may be fixed in a future toolchain — keep the workaround pinned with a comment so the regression is traceable.

- ImageIO synthesizes a dimension-only EXIF dict on stripped PNG re-encode: the synthesized `{Exif: {PixelXDimension, PixelYDimension}}` describes the re-encoded pixels (not source metadata). Strip-path assertions on `kCGImagePropertyExifDictionary` being `nil` therefore fail. Assert on source-specific markers instead: EXIF `UserComment` must be `nil`, `kCGImagePropertyGPSDictionary` must be `nil`. The synthesize is acceptable because it carries no source information.

- ImageIO CAN round-trip EXIF `UserComment` into PNG on the preserve path: a `kCGImagePropertyExifDictionary` with `kCGImagePropertyExifUserComment` passed via `CGImageDestinationAddImage` to a PNG destination round-trips. PNG-always output (re-encode target) stays honest for the labeled preserve toggle — no need to switch to JPEG. (GPS-in-PNG round-trip is best-effort and was not asserted; if preserve-tolerance ever needs to include GPS markers, switch the preserve output to JPEG or assert the GPS dict separately.)

- Replay clipboard mode had a nested-`if` reachability bug in `HerdrWorkspaceUITest.connectReplay`: `if mode == "clipboard"` was nested inside `if mode == "input"`, so the clipboard branch was unreachable and `--uitest-herdr-mode clipboard` actually served the 4-chunk default `replay-2x2` script (no `presentation-ready`, no OSC52 chunk). Symptom in UI tests: banner never appeared, cmd+v inputs came back as `frozen` (FFI lane never unfrozen — `herdr-client-core activation_cases/begin.rs:131`: "pane input is blocked while frozen"). Fixed to a sibling branch; verify with the unit suite's `testRemoteClipboardArrivesAsPendingNotPasteboard` (same 9-chunk script via `connectThroughFence`) which caught the bug only indirectly because the unit suite never went through `HerdrWorkspaceUITest.connectReplay`. Lesson: the DEBUG replay driver is a second code path from the unit suite and deserves its own smoke.

- `ServerMessage::Clipboard { data: String }` carries base64 with no pane field — endpoint-level attribution only. The matching client message is `ClientMessage::ClipboardImage { target: ClientClipboardImageTarget::Pane(String), extension: String, data: String }`. `accept_clipboard` errors surface through `herdr_client_receive` as `HERDR_CODE_CLIPBOARD_DROPPED` (code 16) — non-fatal; the pump catches per-chunk and stays Online. `send_clipboard_image`: `len > cap` returns `HERDR_CODE_INVALID_ARGUMENT`; `len == cap` is accepted (the FFI uses strict `>`, not `>=`); `len == 0` returns `HERDR_CODE_INVALID_ARGUMENT`. None of these is exported as a constant in `HerdrCore.h` — keep the app's behavior aligned by reading from `HERDR_CODE_*` constants only.

- Paste-permission state poisons every later test on the simulator: an app killed while its OOP paste-authorization prompt is pending records a sticky `kTCCServicePasteboard` row (tccd "downgrading auth"), after which `UIPasteboard.general.hasStrings` returns false for the bundle — `canPerformAction(paste:)` goes false, UIPasteControl finds no handler, and every paste gesture silently no-ops (no prompt, no read, no echo). Deterministic hygiene for paste UI suites: `xcrun simctl privacy <udid> grant pasteboard com.bicterm.app` before the run (an Apple-tool simulator-state write; nothing in-repo), and treat "control tap does nothing at all" as TCC state first, code second. The tccd row is inspectable at `<sim>/data/Library/TCC/TCC.db`.
- UIPasteControl under synthesized XCUI taps delivers NOTHING on this iOS 26.5 simulator — neither the responder-chain `paste(_:)` delivery (verified with the override + `canPerformAction` in place and pasteboard granted) nor a manually added `primaryActionTriggered` UIAction fires; the app never even issues a pasteboard item request. The shipped `herdr-paste-control` is therefore a plain SwiftUI `Button(action: beginPaste)` — tap-mediated read, no system consent window — while the input field keeps its `paste(_:)` override + `canPerformAction` + super-forwarded hardware cmd+v so the consented path survives for real chords and the edit menu. If UIPasteControl is ever retried, prove delivery with a granted pasteboard and an NSLog at the handler before trusting it.
- SwiftUI `Text` number interpolation applies locale grouping: `"\(100000) bytes"` renders "100,000 bytes" — an a11y-label needle `CONTAINS "100000 bytes"` fails. Use `\(n, format: .number.grouping(.never))` for any user-visible count a test pins (the echo lines elsewhere interpolate into plain strings and never group; the alert now matches that convention).
- The herdr replay driver is NOT a separate intake: `connectReplay` feeds the same `runInboundPump` with a real FFI `HerdrClient`, so once the mode branch is reachable the pump's post-chunk `client.takeClipboard()` routes the OSC52 payload to `remoteClipboardArrived` exactly like a live session — no transport-level clipboard hook is needed. Corollary: the injector `cmd+v` token must be a `.paste` step calling `field.paste(nil)` (synthetic presses carry no UIPressesEvent, so the super-forwarding path is unreachable for them); with the pasteboard pre-granted the resulting read is silent and the test's springboard Allow-Paste dismissal becomes a no-op fallback instead of a load-bearing flake.

- Atlas iPad 2/5 "dead paste button" was TCC state, not layout: a runner-seeded pasteboard is CROSS-APP content, so the gesture read raised the SpringBoard paste prompt on the ungranted iPad and blocked the app's main thread — the tap's post-event idle-wait then hung for minutes (163 s / 288 s) and the kill wrote another sticky tccd denial. Discriminators: the own-origin re-paste test (`testRemoteClipboardCopyGestureWritesAndRepastes`) passed on the same iPad (button + beginPaste demonstrably fire), and `pasted`/`tccd` sim logs showed "Paste requires user authorization. Prompting..." + "downgrading auth to 3" at each failure timestamp. Fix: the two runner-seeding tests now seed via `HERDR_UI_TEST_PASTEBOARD` — the app writes the string at boot (own-origin; never prompts) — while the cmd+v chord test KEEPS the runner seed as the deliberate prompt+springboard-dismissal path. After this the suite is grant-free green on both canonical sims; `simctl privacy reset pasteboard com.bicterm.app` cleans a poisoned state (verify via the sim's TCC.db).

## Herdr lifecycle (phase 2, task 19)

- Protocol-extension default implementations are NOT dynamic-dispatch witnesses: `termination()` existed as an extension default on `HerdrByteTransport`, so existential calls always returned `.unknown` and the replay transport's `exitStatus` was silently ignored (serverShutdown taxonomy test caught it). Any conformer-overridden method called through `any Protocol` must be a FORMAL requirement; a default in the extension alone is dead code at the existential.
- `withTaskGroup` races against non-cancellable awaits deadlock: `cancelAll()` cannot abort `Task.value` waits or continuation-based `awaitTermination()` waits, and the group implicitly awaits every child at scope exit. Both the pump's termination wait and detach's drain initially hung whole test cases this way. Bounded POLLING with an abandoned detached waiter (lock-confined box + deadline loop) is the safe pattern when the underlying continuation may never resume.
- Reconnect backoff off-by-one: the loop sleeps BEFORE recursing, so the sleep must use `delay(beforeAttempt: attempt + 1)` — passing the CURRENT attempt number makes attempt 2 immediate (attempt 1's wait is `.zero` by definition) and tests observe factory calls skipping 1→3.
- A fresh snapshot frame RESTARTS the activation transaction: between snapshot-rev2 and a new surface commit the FFI's committed surface pane list is empty, so `send_pane_input` returns StaleTarget for input that typed fine milliseconds earlier. Replay scripts that type text must keep the INITIAL script at the plain 8-chunk fence; continued-output snapshot tails belong ONLY on reconnect scripts (after the fence re-establishes).
- The full fence costs ~6 client wire frames (hello + activation/evidence/presentation controls), so "the wire carries only the fresh hello" assertions are wrong. Assert first-frame-is-hello (envelope check) + absence of the specific replayed input frame instead.
- Swift CRLF split gotcha, again: `split(separator: "\n")` never separates `\r\n`-terminated lines (CRLF is one grapheme cluster) — the probe parser got nil platforms until switched to `split(whereSeparator: \.isNewline)`.
- Real scene backgrounding in UI tests works via `XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()` → app.activate() on BOTH canonical sims, including a workspace presented as fullScreenCover (scenePhase .background fires there); Settings' activation can lag or drop — poll `app.state != .runningForeground` and re-activate once.
- The fixture sshd's exec PATH (`~/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin`) excludes `~/.local/bin` and `/opt/homebrew/bin`, so `command -v herdr` fails there even on a dev host with herdr installed: the probe-missing case is deterministic live against the fixture sshd with search paths pointed nowhere, and the found+compatible case rides a repo-local `Fixtures/herdr/fake-herdr-status` shim answering `status client --json` (generation 1).
- `herdr status client --json` (upstream cli/status.rs) is the structured probe surface: compact single-line JSON with version/endpoint_protocol_generation/endpoint_capabilities/binary. The probe one-liner prefixes lines with `bpo:` sentinels and bounds the status read with `head -c 4096`.
- Model teardown's `transport.close()` is fire-and-forget (a detached Task) — `isClosed` assertions need bounded waits right after `.failed` transitions, or they race.
- Pre-existing working-tree state a task inherits: ProxyJumpTests/CoderServersUITests modified Sep 9 (prior session), the two read-only spec docs untracked-but-present, and several g12 evidence logs dirty. None are ours — stage only the task's own files and report the rest.

## T4 repair (2026-09-11) — ProxyJump first-hop failure regression

- JumpChainBuilder's failure teardown was ALREADY index-safe: every failure
  path closes `established` by array iteration (empty array → zero
  iterations), candidates append only after success, and the single indexed
  access `endpoints[failingIndex - 1]` is bounded by construction
  (ownerIndex = loop index, targetIndex = index + 1). Hardening requests
  against it should be answered with an audit + regression test, not edits.
- Guaranteed-refused first hop for jump-chain tests: dial 127.0.0.1:1
  (loopback ECONNREFUSED is instant, ~4ms test). It touches no fixture port,
  so it cannot perturb the PerSourcePenalty cadence between the hop2 auth
  tests — safe to slot anywhere alphabetically.
- A first-hop TCP refusal surfaces as `.hopFailed(hopIndex: 1, ...,
  underlying: .unreachable)` AFTER exactly one key resolution
  (makeUserAuthDelegate runs before bootstrap.connect in NIOJumpDialer.
  connectTCP) — `RecordingKeyProvider.calls` is the chain-abort oracle.
- ProxyJumpTests runs under the SPM package scheme (`scripts/test-core.sh`
  style, target BicTermCoreTests), NOT the app's BicTermTests bundle; the
  task-template xcodebuild command's `-only-testing:BicTermTests/...` would
  silently match zero tests.
