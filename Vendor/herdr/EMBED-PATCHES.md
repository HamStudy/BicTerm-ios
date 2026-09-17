# herdr embed patch series

Baseline: herdr `b99002ac99b09e00b4ca692436cb15a6b0d676f1` (v0.9.0), the same
pin as `MODIFICATIONS.md`. The pristine upstream checkout under `upstream/`
stays untouched; these patches are applied by `scripts/herdr-embed-prepare.sh`
into a working copy under `.build-artifacts/herdr-embed/`.

Purpose: let the full herdr TUI client compile and link for
`aarch64-apple-ios` so it can be embedded in-process by the BicTerm app
(plan `.omo/plans/herdr-embed.md`, task 1). Patches 1-3 are written to be
upstreamable; patch 4 is BicTerm-specific and feature-gated.

## Series

| Patch | Files | Change | Upstreamable |
| --- | --- | --- | --- |
| `0001-build-map-iOS-zig-targets-and-allow-a-prebuilt-libgh.patch` | `build.rs` (+24) | Map `aarch64-apple-ios`/`-sim` to zig targets `aarch64-ios`/`aarch64-ios-simulator`; add `HERDR_LIBGHOSTTY_VT_PREBUILT` escape that links a supplied `libghostty-vt.a` instead of running the vendored `zig build` (needed on macOS 26 where zig's build-runner host link is broken, and for cross builds) | yes |
| `0002-platform-cover-remaining-unix-helpers-in-the-fallbac.patch` | `src/platform/fallback.rs` (+9) | Re-export `wait_client_stream_readable` and define `foreground_process_group_id_for_tty_fd` (tcgetpgrp, identical to macos.rs/linux.rs) under `cfg(unix)` so unix fallback targets compile | yes |
| `0003-lib-split-the-crate-into-a-library-plus-a-thin-herdr.patch` | `src/lib.rs` (new, verbatim move of the former `src/main.rs` plus 12 lines), `src/main.rs` (reduced to a 5-line shim) | Crate root moves to `src/lib.rs`; exposes `pub fn run()` (the old `fn main` body) and `pub use client::run_client` so embedding frontends link the client instead of spawning a process | yes |
| `0004-transport-add-bicterm-transport-feature-for-host-inj.patch` | `Cargo.toml` (+8), `src/remote/saved.rs` (+~60) | New `bicterm-transport` cargo feature: `connect_saved_ssh` drops the `ssh` subprocess bridge (`RemoteSsh` probes + `SshStdioBridge`) and connects to a host-provided per-machine socket at `{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock`; handshake/supervision unchanged. Default builds keep the stock body byte for byte | no (BicTerm embed) |
| `0005-embed-never-exit-the-host-process-from-run_cl.patch` | `Cargo.toml` (+5), `src/client/mod.rs` (+9) | New `bicterm-embed` cargo feature: `run_client_with_mode`'s non-detached loop-failure path returns `io::Error` from `run_client` instead of `std::process::exit(1)` — an embedding host owns the process lifetime and records the exit detail. Stock CLI builds keep the exit contract byte for byte. `herdr-ios-embed` enables the feature on its dependency unconditionally | yes (upstream may want a no-exit embedding mode) |
| `0006-embed-socketpair-stdio-tty-and-geometry-seams.patch` | `src/client/terminal_setup.rs` (+29), `src/platform/unix_common.rs` (+19), `src/client/terminal_geometry.rs` (+12) | Extends `bicterm-embed`: when stdin is not a tty, `setup_terminal` enters the alternate screen without `ratatui::init` (crossterm raw mode would tcgetattr `/dev/tty`, absent in the iOS app sandbox) and the restore path leaves the screen without `disable_raw_mode`; `read_terminal_grid_size` prefers the host-published `HERDR_EMBED_COLS`/`HERDR_EMBED_ROWS` grid (TIOCSWINSZ/TIOCGWINSZ fail ENOTSUP on sockets); `ioctl_terminal_geometry` returns None so crossterm cannot reach through `/dev/tty` on a host. Stock builds keep every path byte for byte | no (BicTerm embed; the socketpair redesign is forced by the device sandbox) |

## Feature-gating contract

Without `--features bicterm-transport` the patched tree behaves exactly like
stock herdr: the default `connect_saved_ssh` body is unchanged, no new
dependencies, no behavior change. The feature is never enabled by BicTerm's
stock builds. Same shape for `bicterm-embed` (patches 0005 and 0006):
without it `run_client` keeps the upstream `std::process::exit(1)` contract
and every terminal-setup/geometry path is byte-for-byte upstream; only the
`herdr-ios-embed` staticlib selects the error-return and socketpair-stdio
seams.

## libghostty-vt link stub

`libghostty-vt.linkstub-aarch64-ios.a` is a **link stub only**: an arm64
static archive defining the 173 `ghostty_*` symbols referenced by
`src/ghostty/bindings.rs` as aborting stubs, compiled with
`zig cc -target aarch64-ios` + `zig ar`. It proves the Rust link pipeline for
iOS but cannot parse VT output. It is superseded by the real
`libghostty-vt.a` produced for `aarch64-ios` (plan task 2), supplied via
`HERDR_EMBED_GHOSTTY_VT_A` or dropped into
`vendor/libghostty-vt/zig-out/lib/` of the working copy.

- sha256: `282f51909742aa683759252c8cec9ee347d73f528d0a491ee4b1427b830abd6f`

## Build proof

```sh
scripts/herdr-embed-prepare.sh
# runs, inside repo-local caches (RUSTUP_HOME/CARGO_TARGET_DIR under
# .build-artifacts/, toolchain pinned by upstream rust-toolchain.toml 1.96.1):
#   cargo build --locked --target aarch64-apple-ios
#   cargo build --locked --features bicterm-transport --target aarch64-apple-ios
```

Evidence: `.sisyphus/evidence/herdr-embed-t1.log`.

## Embed FFI crate (plan task 3)

`Vendor/herdr/herdr-ios-embed/` is a standalone workspace (excluded from the
Vendor/herdr workspace) that path-depends on the patched working copy above
and exposes the in-process embed C ABI (`herdr_embed_*`: start/stop,
write(input), cancellable blocking read(output), env-published winsize) with the
cbindgen header at `herdr-ios-embed/include/HerdrEmbed.h`. Build proof:
`scripts/herdr-embed-prepare.sh` now (a) defaults
`HERDR_EMBED_GHOSTTY_VT_A` to the REAL committed aarch64-ios archive from
plan task 2 (the link stub stays available via the env override), and
(b) after the herdr binary proofs, builds the embed crate for
`aarch64-apple-ios` in both feature variants, audits the staticlib for the
ABI + all 173 `ghostty_*` symbols, and regenerates/verifies the header.
Host harness tests run the real client against the pinned prebuilt server
fixture through the shim; evidence `.sisyphus/evidence/herdr-embed-t3.log`.
No patch-series files were modified for this task; only this script's
default and appended proof step changed.

## Rebase instructions

1. Update the `upstream/` checkout to the new herdr commit and record it in
   `MODIFICATIONS.md` / `UPSTREAM_SOURCE.sha256`.
2. Re-extract a working copy (`git archive <new-base> | tar -x`), then
   `git apply --3way` each patch in order; resolve conflicts.
3. Re-verify: `cargo check --target aarch64-apple-ios` (default and
   `--features bicterm-transport`), then the full build proof above.
4. Regenerate the link stub only if `src/ghostty/bindings.rs` gained symbols
   (extract `extern "C"` fn names, emit stub definitions, `zig cc -target
   aarch64-ios`, `zig ar`), and update the sha256 here.

## Updating the pinned herdr ref (HERDR-UPDATE runbook)

`scripts/herdr-embed-update.sh` is the ONLY sanctioned path for moving the
embed stack to a new herdr release:

```sh
HERDR_NEW_REF=<sha|tag|branch> scripts/herdr-embed-update.sh
```

What it does, in order:

1. Fetches the ref in `Vendor/herdr/upstream/` and resolves the commit.
2. Extracts a pristine tree to `.build-artifacts/herdr-embed-update/` (own
   git repo, so `git apply` behaves — same trap as the prepare script).
3. Replays this patch series with `git apply --3way`. **Rejects are the
   only acceptable failure point**: fix the `.patch` files in
   `embed-patches/` (or resolve in the tree and re-split the diff), never
   the pristine sources. A proof failure after a clean apply also means the
   corresponding patch drifted semantically — fix it at the patch layer.
4. Runs the contract check (below).
5. Runs the mechanical proofs: herdr binary builds for
   `aarch64-apple-ios` (both feature variants), the embed FFI builds
   (both variants, against the replay tree via a temporary working-copy
   swap), a report-only cbindgen drift check, and the T3 behavioral
   harness (`lifecycle`, `headless_frame`, `headless_detach`,
   `headless_resize` — the last three need the pinned prebuilt server
   fixture binary from `scripts/herdr-server-fetch.sh`).
6. Prints the promotion checklist (bump `BASE=` in
   `scripts/herdr-embed-prepare.sh`, `MODIFICATIONS.md`, the provenance
   tar/sha256; re-run prepare + `scripts/herdr-embed-core.sh`; rebuild the
   app).

### Swift↔herdr contract rule (enforced)

The generated `HerdrEmbed.h` ABI is the **only** Swift↔herdr contract.
Swift code must never depend on herdr internals — no vendored-source
reach-throughs, no re-declared types, no other herdr headers. Concretely:

* `herdr_embed_*` C symbols may appear ONLY in the app's Embed wrapper
  (`BicTerm/Herdr/Embed/`), its tests (`BicTermTests/Herdr/`), and the
  clang-module header itself (`HerdrEmbedC/include/HerdrEmbed.h`, the
  committed cbindgen copy — never hand-edited; `scripts/herdr-embed-core.sh`
  fails loudly on drift).
* Swift files may import herdr code only through the module hosts
  (`HerdrEmbed`, the module name of the `HerdrEmbedC` clang host, for the embed ABI, `HerdrClientCore` for the older
  workspace client).
* New herdr capabilities needed by Swift go through the runbook: extend
  the embed FFI crate's C ABI first (`Vendor/herdr/herdr-ios-embed`), then
  regenerate the header, then consume it from Swift.

The update script greps for both rules and fails the run on violations;
`scripts/herdr-embed-core.sh` re-checks the header drift on every build.

## Swift embedding (plan task 4)

`scripts/herdr-embed-core.sh` assembles
`.build-artifacts/herdr/HerdrEmbed.xcframework` (headerless, device +
simulator, release profile) from the embed staticlib and drift-checks the
committed `HerdrEmbedC/include/HerdrEmbed.h`. The simulator slice swaps
the simulator `libghostty-vt.a` into the working copy for its build and
restores the device archive afterwards. dSYMs are archived per slice
since T8 (see "Hardening" below).

## Transport injection (plan task 5)

Since T5 the same script builds BOTH staticlib slices with
`--features bicterm-transport` (patch 0004's seam): the embed archive
drops the local `ssh` subprocess bridge and dials the host socket at
`{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock` instead. The Swift host
side lives outside the vendor tree (`BicTermCore/.../HerdrEmbedBridgeServer`
UDS listener + per-connection `remote-client-bridge` exec relay;
`BicTerm/Herdr/Embed/HerdrEmbedTransport` coordinator, catalog seeding,
TOFU reuse) and seeds the client's saved-endpoint catalog under
`{App Support}/herdr-embed/state-home/herdr/client/`. The transport
directory is a SHORT RELATIVE path (`tmp/herdr-embed-transport`) resolved
against the process cwd the coordinator pins — `sockaddr_un.sun_path`
holds 104 bytes on Darwin and app-container paths exceed that. Evidence:
`.sisyphus/evidence/herdr-embed-t5.log`.

## Herds through the real client (plan task 6)

No Rust-side change (patch set frozen since T5): T6 is entirely host-side.
A herd seeds the client catalog with one entry per machine — each link
resolves the machine's connection at open time, applies the herd-local
session-name override the same way the native path does, and gets its own
bridge socket on its own established carrier (jump chains included).
Bring-up failure isolation mirrors the native herd: one dead machine
never blocks the others (it stays in the catalog and the client renders
its own dial-failure state); only a total failure surfaces as a typed
transport error. One Swift-side core fix shipped with it: an accepted
child whose exec open fails on a dead carrier (the redial the client's
supervisor performs after a server dies) must finish its `NIOAsyncWriter`
before being dropped — NIO's writer deinit precondition-fails otherwise
and kills the whole process. Evidence: `.sisyphus/evidence/herdr-embed-t6.log`.

## Switch + retire (herdr-embed task 7, 2026-09-13)

No patch-series change — the embed stack (1–4 + libghostty-vt iOS) is
unchanged from T5/T6. T7 is the host-side switch: the `HERDR_EMBED`
Swift compile flag (added in T4 for the trial pair) is removed from
`project.yml`; the embed path is the only build path now. The native
SwiftUI herdr workspace interior (`HerdrWorkspaceView` + `HerdMachineSwitcher`
+ `HerdrPaneSurfaceView` + `HerdrInputField` + `HerdrKeyMapper` +
`HerdrImagePasteSheet` + `HerdrDiagnosticView` + `HerdrProbeDiagnosticView`)
retires; the connector/coordinator/endpoint-model/probe pieces stay (the
embed runtime owns TOFU/probe/bridge through them, and
`HerdSessionCoordinator.liveLookup` is the herd-seed resolver).
`HerdrConnectUITests` rewrites against the embed surface; `HerdrEmbedUITests`
gains a `XCUIDevice.orientation` landscape parity test. The Swift↔herdr
contract is unchanged — `HerdrEmbed.h` is still the only seam
(`HerdrEmbedC/include/HerdrEmbed.h`, cbindgen-committed, drift-checked
on every `herdr-embed-core.sh` build). Evidence:
`.sisyphus/evidence/herdr-embed-t7.log`,
`.sisyphus/evidence/herdr-embed-t7/`.

## Hardening (herdr-embed task 8, 2026-09-14)

Sync honesty (bounded `bufferingNewest(256)` output pipeline with loud
drop counting + T12-style VT-reset/SIGWINCH resync), memory/CPU bounds
(flood bound, fd/thread audits, bounded redial churn), authLost + trust
edge tests, and automatic font parity from SwiftTerm metrics all landed
host-side in commit `713dcfe` (`HerdrEmbedHardeningTests`).

Rust side adds patch 0005 (`bicterm-embed`): `run_client`'s non-detached
loop-failure path returns an `io::Error` instead of
`std::process::exit(1)`, which used to take the whole iOS host process
down after a detach-key stop (the T8 probe documented the poison).
`herdr-ios-embed` enables the feature on its dependency, so every embed
staticlib gets the error-return path; the stock CLI contract is
unchanged. The env-gated detach probe
(`HERDR_EMBED_DETACH_PROBE=1`, solo) now ends with the host process
alive — gate kept for detach-key timing sensitivity, not poison.

Keeping the process alive exposed a second, latent detach bug (previously
masked by the process death): a self-exited client was never stopped —
the leaked instance kept the pty master open with process stdio still
dup2'd onto the dead slave, and the NEXT client's `dup2` deadlocked on
the fd lock an abandoned slave reader held. Two-sided fix: the embed
crate's client thread now performs self-exit cleanup (master close first,
then stdio neuter — stop() stays the owner of the saved-stdio restore),
and the Swift runtime's `handleExit` runs `stopBlocking` on the same
stop→transport ordering as `requestStop`. Proofs: the detach probe plus a
canary class in one app process (next live boot works, 0.24s).

Fixture honesty follow-up (test-only): the server-death hardening test
learned that `remote-client-bridge` (exec'd through the fixture sshd with
HERDR_SOCKET_PATH set) AUTO-STARTS a replacement server on its next
redial — that server belongs to no pidfile, which is why the old
restore's second spawn raced and left pidfile→dead-pid receipts. The test
now waits for the auto-started server (direct spawn as fallback) and its
teardown reseeds deterministically (`herdr server stop` → clear sockets
and pidfile → one fresh spawn whose pid is recorded), leaving
pidfile == live owner for the next consumer.

dSYMs for the embed archive (T4 residual): `herdr-ios-embed`'s release
profile carries `debug = 2` (LTO off — rustc bitcode vs Apple linker,
same rationale as `Vendor/herdr`'s `ios-release`), and
`scripts/herdr-embed-core.sh` archives
`.build-artifacts/herdr/embed-dsym/{device,simulator}/HerdrEmbed.<slice>.dSYM`
via the same throwaway stub-dylib + `dsymutil` pattern as
`build-herdr-core.sh`. Evidence: `.sisyphus/evidence/herdr-embed-t8.log`.

## Socketpair stdio redesign (2026-09-17)

The embed client's stdio transport is an AF_UNIX stream socketpair, not a
pty pair. Why (device-proven, `.sisyphus/evidence/device-probe.log`,
`Docs/DEVICE-SANDBOX.md`): the iOS app sandbox denies `openpty` and
`open("/dev/ptmx")` with EPERM on physical devices — the embed start's
first op died there (`herdr embed error 4: start: Operation not
permitted`), while `socketpair`, `fcntl(F_SETFL, O_NONBLOCK)`, and `dup2`
are all legal on the same device. The simulator does not enforce the app
sandbox profile, which is why every earlier pty-based run passed there.

Two-sided change:

* **`herdr-ios-embed` (this repo, direct edits — not patches)**: `src/pty.rs`
  is deleted (the pty path is gone, not gated) and `src/stdio.rs` replaces it
  — `IoPair::open` is `socketpair(AF_UNIX, SOCK_STREAM)` with the host end
  non-blocking (a client that stops draining surfaces as `WouldBlock`, a
  typed IO error, instead of blocking the host write path) and the client
  end blocking. `instance.rs` keeps the fd-hygiene/Drop semantics, the
  start/boot-gate shape, and the stop ordering (host close before the
  /dev/null neuter — the Darwin dup2-over-a-blocked-reader deadlock lesson).
  Resize is explicit state: `set_winsize` publishes
  `HERDR_EMBED_COLS`/`HERDR_EMBED_ROWS` (start seeds them from the config
  grid; the client thread re-asserts under the env gate) and NO
  `ioctl(TIOCSWINSZ)` (ENOTSUP on sockets, both platforms) and NO SIGWINCH
  self-signal (no pty to size). The C ABI is unchanged.
* **Patch 0006 (this series)**: the client's tty assumptions are bypassed
  behind `bicterm-embed` when stdin is not a tty — `ratatui::init` /
  `try_restore` (raw mode would tcgetattr `/dev/tty`, absent in the app
  sandbox; on a host it would raw-mode the WRONG terminal), the grid from
  the env seam instead of TIOCGWINSZ, and no exact-geometry ioctl
  (`crossterm::terminal::window_size` opens `/dev/tty` first — on a host it
  would report the controlling terminal's geometry over the embed grid).
  The client's Unix input path needed no patch: it already reads raw bytes
  from fd 0 (`unix_stdin_reader_loop`), not crossterm's event source.

Host-test fallout (both fixed in the embed crate's tests): the lifecycle
SIGWINCH-delivery test became the env-grid seam test (a silent UDS listener
holds the client in its 5s local-handshake window so `set_winsize` runs
against a live instance — after self-exit the host socket is closed and
`set_winsize` correctly refuses NOT_RUNNING), and the headless detach test
retries the prefix+q pair: the socketpair surfaces the first frame fast
enough that the test's keystrokes can land inside the client's startup
window, where the first snapshot commit clears the prefix state (the pty's
line-discipline latency used to hide this race). The stdio unit tests
serialize on a module mutex and the redirect round-trip drains the host end
first — the test harness's own fd-1 output lands in the socketpair during
the redirect window.

Verification: `cargo test` in `herdr-ios-embed` (unit + lifecycle +
headless frame/detach/resize against the pinned server fixture) green on
the host; `scripts/herdr-embed-core.sh` rebuilds both slices; device proof
`BicTermTests/Device/HerdrEmbedDeviceBootTests.swift` →
`.sisyphus/evidence/embed-device-boot.log`.
