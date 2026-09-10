# T13 extraction boundary escalation — INCOMPLETE

Baseline: herdr v0.9.0,
`b99002ac99b09e00b4ca692436cb15a6b0d676f1`.

## Disposition

The toolchain blocker is resolved. A narrow copy of the protocol and endpoint
modules is not a complete extraction: frozen wire data, desktop conversions,
shell projection, and presentation synchronization cross the proposed crate
boundaries. The full extraction **has not been implemented**. Do not unblock
T14/T16 or treat this directory as a Rust client library.

This assessment does **not** prove that a larger, careful refactor is
structurally impossible. Compiler errors below establish the missing seams,
not impossibility. No production refactoring patches were attempted; only
compile-harness corrections and source-boundary probes were made. Thus the
full task's structural-impossibility condition is not conclusively established.
The task remains incomplete, rather than complete by escalation.

## Exact coupling

All source locations below refer to the pinned checkout in `upstream/`.

| Boundary | Source evidence | Required separation |
| --- | --- | --- |
| Frozen wire records → desktop input | `src/protocol/wire.rs:167,188` contains `WindowsKeyRecord`; `:310-460` converts terminal/raw input through `crate::input`, `crate::raw_input`, and crossterm | Move the complete serialized data definition without changing field/variant order; leave runtime conversion implementations outside the protocol crate |
| Wire records → configuration/API models | `wire.rs:888-901,1025,1045,1072` uses `api::schema::AgentStatus`; `:1321` uses `config::ToastHerdrPosition`; `:971-994` converts custom command actions | Extract frozen shared data separately from configuration loading and command execution; do not delete serialized fields merely because iOS ignores an action |
| Stable welcome → binary build identity | `src/protocol/endpoint.rs:107,125` calls `build_info::version()` | Separate client negotiation records from server-side welcome construction/build metadata |
| Endpoint supervisor → local sockets/desktop SSH | `src/client/endpoint/supervisor.rs:36` owns `ipc::LocalStream`; `:238-307` connects local sockets or `remote::connect_saved_ssh`, performs desktop handshake, clones the stream, and retains the bridge lifetime | Replace connection execution with an injected transport adapter while preserving generations, independent retries, admission, cancellation, and late-result retirement |
| Bounded writer → local socket lifecycle | `src/client/endpoint/writer.rs:6-9,32-69` requires interprocess/LocalStream and a worker lifetime; `:83-117` accounts for queue bytes/messages | Separate transport-independent queue accounting from desktop nonblocking socket I/O; no fake immediate-success sender |
| Activation → shell projection | `src/client/endpoint/activation.rs:19,820-913` accepts `ClientShellState` and commits through `activate_endpoint_projection` and `set_pane_surface`; `activation/protocol.rs:25-95` reads shell generation/boot/revision evidence | Extract a real endpoint-qualified projection state contract and preserve coherent snapshot/surface/geometry validation and rollback |
| Activation → API response/command lane | `activation/protocol.rs:143-218` uses typed API results and `endpoint_commands::parse_response` | Move typed request/response correlation with the coordinator; do not acknowledge arbitrary JSON or bypass negotiated method checks |
| Projection → input, selection, rendering, configuration | `src/client/shell/state.rs:1192-1245` resets gestures, input leases, requests, selection and copy state; `:1247-1385` applies keybindings, graphics scope, boot/revision state, layout invalidation, and selection changes | Separate effects from state without replacing these methods with snapshot assignments or no-op shims |
| Presentation fence → desktop runtime | `src/client/shell_runtime.rs:290-398` handles completion, frame presentation/replay, command-lane advancement, input unfreezing, and successor activation | Port this orchestration with the activation reducer; copying `activation.rs` alone cannot guarantee input remains frozen through the matching presentation fence |
| Remote-only home → assumed Local endpoint | `registry.rs:92-98,130-133` defaults to Local; `shell/endpoints.rs:29-37,70-89` inserts/falls back to Local | Introduce a neutral unavailable selection explicitly; never create an iOS server or silently select a different remote |

The shared shell state is not just a model import: `shell.rs` includes the
actions, input, mouse, render, configuration, settings, graphics, and overlay
modules. Pulling it wholesale contradicts the narrow client-core boundary.
Removing those modules requires preserving their load-bearing state/effect
interactions in new interfaces, not just resolving names until Cargo is green.

## Executed probes

The ignored `.scratch/herdr-boundary-probe/` contains unmodified source copied
with `git archive`, a local manifest, and a small module harness. It is not a
deliverable, has no public client API, and has no production feature set.
Every command ran from the BicTerm root with:

```sh
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
```

1. Direct protocol harness: failed. Initial errors included harness mistakes
   (crossterm's disabled events feature and incorrect module placement).
   These initial errors are **not** extraction evidence.
2. Corrected protocol harness, preserving the upstream module hierarchy and
   enabling the referenced event types:

   ```sh
   cargo +stable check --manifest-path .scratch/herdr-boundary-probe/Cargo.toml
   ```

   Failed with 33 compiler errors, including unresolved `input`, `raw_input`,
   `terminal_theme`, `api`, `config`, and `build_info` modules. Full output:
   `.sisyphus/evidence/phase2-h13-protocol-boundary-corrected.log`.
3. Added the unmodified complete endpoint module tree:

   ```sh
   cargo +stable check --manifest-path .scratch/herdr-boundary-probe/Cargo.toml --features coordinator
   ```

   Failed with 95 compiler errors, including `ipc::LocalStream`,
   `client::shell`, `client::endpoint_commands`, `remote`, and desktop handshake
   dependencies. Full output:
   `.sisyphus/evidence/phase2-h13-coordinator-boundary.log`.
4. Isolated upstream health state, disabling the other source modules:

   ```sh
   cargo +stable test --manifest-path .scratch/herdr-boundary-probe/Cargo.toml --no-default-features
   cargo +stable build --manifest-path .scratch/herdr-boundary-probe/Cargo.toml --no-default-features --target aarch64-apple-ios
   cargo +stable build --manifest-path .scratch/herdr-boundary-probe/Cargo.toml --no-default-features --target aarch64-apple-ios-sim
   ```

   Host: **3 passed, 0 failed**. Both iOS builds passed. This proves the
   repository-local toolchain works and the health module is independently
   compilable; it does **not** verify the coordinator, full protocol, or client.
   Logs: `phase2-h13-health-probe.log`, `phase2-h13-health-ios.log`, and
   `phase2-h13-health-ios-sim.log` under `.sisyphus/evidence/`.

LSP diagnostics for the small probe harness were attempted but the daemon
timed out. Compiler output, not LSP, establishes the results above.

## Concrete continuation options

1. **Maintained render-neutral extraction (recommended):** retain task 13 but
   explicitly carry out the larger seam refactor: frozen data/conversion split,
   typed endpoint API carriers, injected connection execution, bounded writer,
   projection/input-effect boundary, then activation and presentation replay.
   Port upstream adversarial activation tests before replacing any shell method.
   This keeps exclusions intact but is more than a two-directory copy.
2. **Upstream alignment:** ask maintainers through the permitted Discussions
   path to establish the protocol/state/effect boundary and generation-1 fixture
   contract. A local draft is in [UPSTREAM_PROPOSAL.md](UPSTREAM_PROPOSAL.md).
   Do not wait for a response before maintaining the local fork.
3. **Larger desktop-shell port:** would retain more upstream implementations,
   but requires an explicit scope change and renewed dependency/asset audit.
   It is not authorized by the current exclusions and was not attempted.

## Acceptance status

- No `herdr-protocol` or `herdr-client-core` workspace created.
- No full host/triple-target builds or client tests passed.
- No golden-frame fixtures captured; no all-message compatibility claim.
- No production target-resolved graph, SPDX allowlist, or cargo-deny check.
- No exclusion-audit pass: there are no shipping crates to audit.
- No submitted upstream issue/PR/discussion or engagement URL.
- Source pin, archive digest, license copy, and local toolchain are recorded.
- Plan and protected files untouched. No tasks 14–16 started.
- No `feat(herdr): extract ...` completion commit is warranted.
