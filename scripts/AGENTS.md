# scripts/ Agent Notes

Per-script contracts and gotchas for the build/test/fixture shell harness. Root `AGENTS.md` has the command list and containment policy; this file covers what each script actually does and where it bites.

## OVERVIEW
10 bash scripts: cache pinning, Rust FFI xcframework build, herdr embed working-copy prep, libghostty-vt iOS build, SSH fixture lifecycle, core/UI test runners, module-isolation check.

## WHERE TO LOOK
| Script | Role | Gotchas |
|--------|------|---------|
| `env-local-caches.sh` | Pins Go/Rust caches + TMPDIR to `.build-artifacts/` and `.scratch/` | SOURCE it, never execute. Uses `$PWD`; source from repo root. Does NOT set RUSTUP_HOME. |
| `build-herdr-core.sh` | cargo-builds herdr-ios-ffi for ios + ios-sim, cbindgen header, dSYMs, assembles xcframework into `.build-artifacts/herdr/` | Sets RUSTUP_HOME itself. Sources env-local-caches. Wipes output dir each run (idempotent). Full log teed to `.sisyphus/evidence/phase2-h14-build.log`. |
| `fixtures-up.sh` | Starts sshd hop1 (12222), hop2 (12223), Python UDS forwarder; regenerates missing keys; runs ssh self-checks | Idempotent. `HOP1_ALT_KEY=1` flips hop1 to the alternate host key (T7 changed-key test) and restarts hop1 if the active config differs. Exits non-zero when any self-check fails. |
| `fixtures-down.sh` | Kills pidfile processes, removes UDS socket, lsof-sweeps ports 12222/12223, waits for close | Idempotent. Exit 1 only if ports stay LISTENing after 10s. |
| `test-core.sh` | `xcodebuild test -scheme BicTermCore` from the BicTermCore package dir, iPhone 17 Pro sim default | Env overrides below. Greps log for `** TEST SUCCEEDED **`; exit 0 without it becomes 1. |
| `test-ui.sh` | `xcodebuild test -scheme BicTerm` from repo root, iPad Pro 13-inch (M5) sim default | Same overrides. Adds `-skipPackagePluginValidation -skipMacroValidation`. |
| `check-isolation.sh` | Greps `BicTermCore/Sources/` for `import SwiftUI/UIKit`; exit 1 with file:line on hits | Despite the name this is the module-isolation check, not a repo-containment audit. |
| `herdr-vt-build.sh` | Builds the vendored libghostty-vt `.a` for iOS (device default; simulator via `HERDR_VT_TARGETS`) from the pristine upstream source; sha-pinned zig 0.15.2 self-downloads | Bypasses the broken `zig build` runner: materializes the generated modules itself and links the host table generators by replaying zig's `--verbose-link` line through `xcrun ld` (macOS 26 host-link bug). `-target` must precede `--dep`/`-M` args (zig silently ignores it otherwise). `HERDR_VT_BUILD=0` verifies existing artifacts only. A committed copy lives at `Vendor/herdr/embed/libghostty-vt/`; normal builds never run this script. |

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
- Don't weaken the sed anchor in fixtures-up.sh. The match prefix `/Users/richard/code/BicTerm/` keeps its trailing slash so it can't match the `BicTerm-ios/` checkout; the un-anchored version corrupted paths into `BicTerm-ios-ios-ios`.
- Don't bypass the `Fixtures/run/bin/ssh` wrapper in self-checks: macOS ssh `-J` re-execs `/usr/bin/ssh` and loses `-o` flags and project known_hosts, so the wrapper translates `-J` into an explicit ProxyCommand.

## NOTES
- build-herdr-core.sh self-installs cbindgen repo-locally (`.build-artifacts/tools/`) via `cargo install --locked` on first run.
- dSYMs are real: each slice's `.a` is linked into a throwaway stub dylib referencing `herdr_client_create`, then `dsymutil` extracts the Rust DWARF. Stub never ships.
- The `nm` audit in build-herdr-core.sh ignores nonzero exit: precompiled rust-std members carry bitcode host nm can't read; only `_herdr_client_create` presence is checked per slice.
- test-core.sh `cd`s into `BicTermCore/` (SPM auto-scheme); test-ui.sh runs from repo root. EVIDENCE_LOG anchoring exists because of that cd.
- Fixture keys are generated if missing and committed if present; passphrase fixture key uses `testpass`. UDS socket perms are self-checked to 600.
