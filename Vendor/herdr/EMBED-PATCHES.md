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

## Feature-gating contract

Without `--features bicterm-transport` the patched tree behaves exactly like
stock herdr: the default `connect_saved_ssh` body is unchanged, no new
dependencies, no behavior change. The feature is never enabled by BicTerm's
stock builds.

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
