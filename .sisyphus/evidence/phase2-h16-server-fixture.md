# T16 Phase B — herdr v0.9.0 host server fixture: BLOCKED-ENVIRONMENT

Date: 2026-09-10. Task 16 (Herdr handshake, state reducer, native workspace UI).

## What was attempted (repo-local, Vendor untouched)

1. Zig preflight: `which zig` -> not found. herdr v0.9.0's `build.rs` hard-
   requires Zig for the vendored libghostty-vt static library.
2. Downloaded the exact required toolchain repo-local:
   `.build-artifacts/tools/zig-aarch64-macos-0.15.2/` (ziglang.org
   0.15.2 tarball, version verified `0.15.2`).
3. Copied the pristine upstream checkout to
   `.build-artifacts/herdr-build/upstream/` (79 MB; `Vendor/herdr/upstream`
   never written: build outputs redirected via `CARGO_TARGET_DIR`,
   `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`).
4. `cargo build --release` with repo-local caches + `ZIG` env pointing at
   the downloaded binary.

## Precise blocker

- `zig build` for vendored libghostty-vt fails while linking ITS OWN build
  runner: `undefined symbol: _abort / _bzero / _sigaction /
  __availability_version_check ...` — libSystem is not being linked at all.
- Reproduced MINIMALLY, independent of herdr: `zig build-exe hello.zig`
  with zig 0.15.2 on this host fails with the same undefined libc symbols.
  Host: macOS 26 (Xcode 26.6). Zig 0.15.x predates this OS; its
  libSystem/dyld shared-cache resolution is broken on it. This is a
  toolchain-vs-host incompatibility, not a herdr defect.
- Version pin is exact: vendored `src/build/zig.zig` `requireZig` enforces
  `major == 0 && minor == 15 && patch >= 2`, so zig 0.16.0 (which exists
  and would likely link) is rejected at compile time by an @compileError.
  ziglang.org publishes no 0.15.x newer than 0.15.2.
- Relaxing the pin means patching `Vendor/herdr/upstream/**` — forbidden
  for T16 (Vendor is read-only for this task).

Log excerpt (`cargo build --release`, tail):

```
error: undefined symbol: _realpath$DARWIN_EXTSN
error: undefined symbol: _sigaction
error: undefined symbol: _sysctlbyname
error: undefined symbol: _waitpid
thread 'main' panicked at build.rs:92:5:
zig build for vendored libghostty-vt failed: exit status: 2
```

## Options for the orchestrator/user

1. Ask upstream (herdrdev/herdr) to bump the vendored libghostty-vt Zig pin
   to a 0.16.x that links on macOS 26, then rebuild (small Vendor refresh).
2. Provide/build on an older macOS/Xcode host (or CI runner) where zig
   0.15.2 links; copy the release binary into `Fixtures/run/herdr/`.
3. Authorize a task-owned minimal Vendor patch (bump `minimum_zig_version`
   in `vendor/libghostty-vt/build.zig.zon` + any 0.16 build fixes) with the
   usual modification-ledger entry; then Phase B's fixture + live-server UI
   test can land as planned.

## Phase B consequences (honestly reported, not silently skipped)

- Live-server UI test (connect -> >=2-pane 2x2 render -> focus switch ->
  resize via real server), live soak, and T15 criterion 2 (full Swift->
  Rust handshake against a real herdr-core binary over HerdrSSHTransport)
  are NOT executed in this environment.
- Everything Phase A is delivered and green: replay-driven handshake/
  snapshot/surface rendering from REAL committed codec frames, version-gate
  diagnostic, fake-transport edge suite, both canonical simulators, soak.
- The live-path plumbing that WOULD carry Phase B (HerdrSSHTransport over
  fixture sshd + `Fixtures/herdr/mock-herdr` shim) is committed and covered
  by T15; only the real server binary is missing.
