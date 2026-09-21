# scripts/ Agent Notes

Per-script contracts and gotchas for the build/test/fixture shell harness. Root `AGENTS.md` has the command list and containment policy; this file covers what each script actually does and where it bites.

## OVERVIEW
13 bash scripts: cache pinning, Rust FFI xcframework build, herdr embed working-copy prep + release runbook, pinned prebuilt herdr server fetch, libghostty-vt iOS build, SSH fixture lifecycle, core/UI test runners + a missing-server evidence wrapper, module-isolation check.

## WHERE TO LOOK
| Script | Role | Gotchas |
|--------|------|---------|
| `env-local-caches.sh` | Pins Go/Rust caches + TMPDIR to `.build-artifacts/` and `.scratch/` | SOURCE it, never execute. Uses `$PWD`; source from repo root. Does NOT set RUSTUP_HOME. |
| `build-herdr-core.sh` | cargo-builds herdr-ios-ffi for ios + ios-sim, cbindgen header, dSYMs, assembles xcframework into `.build-artifacts/herdr/` | Sets RUSTUP_HOME itself. Sources env-local-caches. Wipes output dir each run (idempotent). Full log teed to `.sisyphus/evidence/phase2-h14-build.log`. |
| `herdr-embed-prepare.sh` | Copies the pristine upstream checkout into `.build-artifacts/herdr-embed/`, replays the `Vendor/herdr/embed-patches/` series in order, installs a libghostty-vt `.a` | Default installs the committed LINK STUB (links, but cannot run the zig build). Point `HERDR_EMBED_GHOSTTY_VT_A` at a real artifact from `herdr-vt-build.sh` for a runnable embed. |
| `herdr-embed-update.sh` | HERDR-UPDATE runbook: bumps the pinned herdr ref and replays the embed patch series onto the new pristine tree, with mechanical proofs | Failures must surface as patch rejects — fix the `.patch` files, never the tree. The generated `HerdrEmbed.h` ABI is the ONLY Swift↔herdr contract. |
| `fixtures-up.sh` | Starts sshd hop1 (12222), hop2 (12223), Python UDS forwarder; regenerates missing keys; runs ssh self-checks | Idempotent. `HOP1_ALT_KEY=1` flips hop1 to the alternate host key (T7 changed-key test) and restarts hop1 if the active config differs. Exits non-zero when any self-check fails. |
| `fixtures-down.sh` | Kills pidfile processes, removes UDS socket, lsof-sweeps ports 12222/12223, waits for close | Idempotent. Exit 1 only if ports stay LISTENing after 10s. |
| `herdr-server-fetch.sh` | Downloads the pinned prebuilt herdr server release (v0.9.1 macOS aarch64) into `Fixtures/run/herdr/herdr`, sha256-verified against `Fixtures/herdr/server-0.9.1.sha256` | Standing policy: never build the server from source. Idempotent (a matching binary is left alone); needs network only on first fetch. |
| `test-core.sh` | `xcodebuild test -scheme BicTermCore` from the BicTermCore package dir, iPhone 17 Pro sim default | Env overrides below. Greps log for `** TEST SUCCEEDED **`; exit 0 without it becomes 1. |
| `test-ui.sh` | `xcodebuild test -scheme BicTerm` from repo root, iPad Pro 13-inch (M5) sim default | Same overrides. Adds `-skipPackagePluginValidation -skipMacroValidation`. |
| `test-herdr-missing-server.sh` | Dedicated evidence run for `HerdrConnectUITests.testMissingHerdrServerReachesTypedEmbedState`: flips the fixture topology to herdr-on-12222-ONLY, runs just that test, restores the standard topology afterwards | In-suite the test skips by design under the standard both-ports topology. Fixture socket state is VERIFIED (not assumed) before and after — several writers touch those sockets. |
| `check-isolation.sh` | Greps `BicTermCore/Sources/` for `import SwiftUI/UIKit`; exit 1 with file:line on hits | Despite the name this is the module-isolation check, not a repo-containment audit. |
| `herdr-vt-build.sh` | Builds the vendored libghostty-vt `.a` for iOS (device default; simulator via `HERDR_VT_TARGETS`) from the pristine upstream source; sha-pinned zig 0.16.0 self-downloads | Runs upstream's own build graph on-host: `zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dsimd=false -Dtarget=<t> -Demit-xcframework=false` — the same configuration herdr's build.rs requests (herdr 0.9.1's vendored libghostty-vt requires zig 0.16.0, which also fixed the macOS 26 host-link bug that forced the former hand-materialized replay). `HERDR_VT_BUILD=0` verifies existing artifacts only. A committed copy lives at `Vendor/herdr/embed/libghostty-vt/`; normal builds never run this script. |

## CONVENTIONS
- Env-override contract (test-core.sh, test-ui.sh; all optional):
  - `DEST_OVERRIDE` replaces the full `-destination` string.
  - `DERIVED_DATA` adds `-derivedDataPath`.
  - `ONLY_TESTING` adds `-only-testing:<value>`.
  - `EVIDENCE_LOG` replaces the tee'd log path; relative paths anchor to REPO_ROOT, not the script's cwd.
- Defaults live in `.sisyphus/evidence/` (`task-1-xcodebuild.log`, `task-1-uitest.log`).
- xcbeautify is optional; both test scripts fall back to raw xcodebuild output. Either way the raw log is tee'd and `PIPESTATUS[0]` is the exit status.
- Containment: scripts keep outputs under `.build-artifacts/`, `.scratch/`, `.sisyphus/evidence/`, `Fixtures/run/`. When editing, parameterize paths via env overrides instead of hardcoding, and never point an output outside the repo.
- Scripts resolve ROOT from their own location, so they work from any cwd, but env-local-caches.sh's `$PWD` exports assume repo root.

## ANTI-PATTERNS
- Never execute `env-local-caches.sh` as a subprocess; exports won't survive.
- Never "fix" the headerless xcframework: `-create-xcframework` is called without `-headers` on purpose (ProcessXCFramework would flatten colliding module maps). The clang module lives in `HerdrCoreC/include`.
- Never hand-edit `HerdrCoreC/include/HerdrCore.h`. build-herdr-core.sh regenerates it and FAILS LOUDLY on drift (updates the committed copy, exits 1, asks for re-run).
- Don't weaken the sed anchor in fixtures-up.sh. The match prefix `/Users/localdev/code/BicTerm/` keeps its trailing slash so it can't match a `BicTerm-ios/` checkout; the un-anchored version corrupted paths into `BicTerm-ios-ios-ios`.
- Don't bypass the `Fixtures/run/bin/ssh` wrapper in self-checks: macOS ssh `-J` re-execs `/usr/bin/ssh` and loses `-o` flags and project known_hosts, so the wrapper translates `-J` into an explicit ProxyCommand.

## NOTES
- build-herdr-core.sh self-installs cbindgen repo-locally (`.build-artifacts/tools/`) via `cargo install --locked` on first run.
- dSYMs are real: each slice's `.a` is linked into a throwaway stub dylib referencing `herdr_client_create`, then `dsymutil` extracts the Rust DWARF. Stub never ships.
- The `nm` audit in build-herdr-core.sh ignores nonzero exit: precompiled rust-std members carry bitcode host nm can't read; only `_herdr_client_create` presence is checked per slice.
- test-core.sh `cd`s into `BicTermCore/` (SPM auto-scheme); test-ui.sh runs from repo root. EVIDENCE_LOG anchoring exists because of that cd.
- Fixture keys are generated if missing and committed if present; passphrase fixture key uses `testpass`. UDS socket perms are self-checked to 600.
