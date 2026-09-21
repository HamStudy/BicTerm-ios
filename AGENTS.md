# Agent Instructions

## NEVER Write Outside the Project

**The first and strongest default rule: agents and every subprocess they launch must keep every controllable write inside the repository root (`pwd` of the checkout).** Changing the working directory, invoking another tool, or delegating work does not weaken or relocate this boundary. The only exception is the narrow Apple tooling exception below.

- Never select `/tmp`, `/private/tmp`, `$HOME`, home-directory caches, Downloads, Desktop, or any other external scratch, build, test, log, result, cache, or evidence path.
- Treat DerivedData, result bundles, logs, screenshots, temporary files, package/cache overrides, evidence, generated artifacts, downloads, and tool metadata as agent-controlled outputs subject to this rule.
- Before running any command that can write, inspect every explicit and implicit output, cache, temporary, build, result, screenshot, log, and evidence path and confirm it resolves within the repository root (`pwd` of the checkout).
- Override tools whose defaults write externally. Use repository-local destinations such as `.build-artifacts/DerivedData/<task>`, `.build-artifacts/xcresults/`, `.sisyphus/evidence/`, and `.scratch/`.
- Apple Xcode and CoreSimulator tooling may perform incidental system-managed writes outside the repository only when those writes are inherent, cannot be redirected, and the tooling is required for build, test, or simulator QA. This permits only Apple-created simulator/device state and unavoidable Apple tool metadata; it does not permit agents to choose external output, cache, log, screenshot, result, temporary, package, evidence, or scratch paths.
- Outside that narrow exception, do not run a command when all of its writes cannot be redirected into the project or when containment cannot be guaranteed. The exception does not apply to non-Apple tools.
- Ensure scripts, child processes, build systems, test runners, simulators, package managers, and other delegated tools obey the same boundary.

No convenience, default behavior, debugging need, or evidence requirement permits any exception beyond the unavoidable Apple tooling writes defined above.

## NEVER Touch the Hardware Device Without Explicit Permission

**Physical iOS devices belong to the user. Agents may use a hardware device only when the user explicitly authorizes it for the work at hand** — an unlock performed by the user is not authorization, and silence is never authorization.

- Device-requiring operations — app install, launch, `xcodebuild test` with a device destination, `devicectl` copies to/from the app container, lock-state or other device queries — are forbidden without that explicit authorization.
- Never poll or wait for device availability: no lock-state probe loops, no retries that wait for an unlock, no periodic re-checks. Waiting for access is wasted work by definition.
- Instead: do everything device-free first (local builds such as `build-for-testing`, simulator suites, fixture-based tests), then ask the user once to intervene, state the exact resume commands, and stop.

## NEVER Sleep Longer Than 180 Seconds In One Command

**A single `sleep`/blocking wait is capped at 180 seconds — the ceiling, and it must be rare.** Long blind sleeps waste the session and hide real progress.

- Never issue `sleep 200`, `sleep 240`, or any wait over 180s — not directly, not inside retry loops, not in delegated worker scripts, not as a "wait for build/test" shortcut.
- Prefer bounded readiness polling: a loop of short sleeps (5–30s) that CHECKS AN ACTUAL CONDITION each iteration (port listening, file present, process exited, log marker appeared) with a bounded iteration count and a hard failure when exhausted — e.g. `for i in {1..12}; do nc -z 127.0.0.1 12222 && break; sleep 10; done`.
- Collision/backoff retries follow the same shape: check-then-short-sleep, never one long sleep.
- This rule binds every agent and every delegated subprocess; orchestrators must reject worker reports that contain a >180s sleep and re-dispatch with the bounded-polling pattern (user directive, 2026-09-21).

---

# PROJECT KNOWLEDGE BASE

**Generated:** 2026-09-20 · **Branch:** main

## OVERVIEW
iOS 18+ SSH terminal (SwiftUI, Swift 6 strict concurrency) on vendored SwiftNIO SSH + SwiftTerm forks; also a herdr workspace client via a Rust FFI core. Xcode project is Xcodegen-generated; platform-agnostic logic lives in a SwiftPM core package.

## STRUCTURE
```
BicTerm-ios/
├── BicTerm/            # iOS app (SwiftUI): Terminal, Herdr, Herds, Sessions, Connections, Keys, Agent, Settings, Security, Design
├── BicTermCore/        # SwiftPM core — SSH/transport/session logic, no SwiftUI/UIKit
├── BicTermTests/       # Core + app-logic unit/integration tests
├── BicTermUITests/     # XCUITest suites (FreeformResize, TerminalToolbar, herdr embed, ...)
├── HerdrClientCore/    # Swift actor wrapper over the herdr Rust FFI (3 files, framework target)
├── HerdrClientCoreTests/ # HerdrClientCore smoke tests (golden-frame replay)
├── HerdrCoreC/         # Clang-module host exposing cbindgen HerdrCore.h (stub.c only)
├── HerdrEmbedC/        # Clang-module host exposing cbindgen HerdrEmbed.h (stub.c only)
├── Fixtures/           # Local test fixtures: sshd (ports 12222/12223), UDS forwarder, herdr, keys
├── Vendor/             # Vendored forks: SwiftTerm, swift-nio-ssh, herdr (Rust)
├── scripts/            # Build/test/fixture harness (12 shell scripts, env-override contract)
├── Docs/               # Design/traceability docs
└── project.yml         # Xcodegen spec — source of truth for the Xcode project
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| App entry / scenes | `BicTerm/App/BicTermApp.swift` | @main, 4 WindowGroups |
| Session lifecycle, reconnect | `BicTerm/Sessions/SessionStore.swift` | registry + toolbar state |
| Terminal view bridge | `BicTerm/Terminal/TerminalRepresentable.swift` | SwiftTerm ↔ SwiftUI |
| Terminal toolbar strip | `BicTerm/Terminal/TerminalToolbar.swift` | esc/ctrl/tab/arrows, GCKeyboard heuristic |
| SSH transport, ProxyJump, agent | `BicTermCore/Sources/BicTermCore/SSH/` | NIO SSH based |
| Transport abstraction seam | `BicTermCore/Sources/BicTermCore/Transport/TerminalTransport.swift` | SSH is one conformer |
| herdr UI (embed host) | `BicTerm/Herdr/` | herdr workspace UI (16 Swift files) |
| herdr client core | `HerdrClientCore/HerdrClient.swift` | actor over C ABI |
| Rust FFI exports | `Vendor/herdr/herdr-ios-ffi/src/abi.rs` | `herdr_client_*` |
| Test fixtures | `Fixtures/` + `scripts/fixtures-up.sh` | sshd 12222/12223 |
| UI tests | `BicTermUITests/` | incl. FreeformResize, TerminalToolbar |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BicTermApp` | @main App | `BicTerm/App/BicTermApp.swift` | scenes, 4 WindowGroups |
| `SessionStore` | ObservableObject | `BicTerm/Sessions/SessionStore.swift` | session registry, reconnect |
| `AppServices` | singleton (`.shared`) | `BicTerm/Connections/AppServices.swift` | DI root |
| `TerminalTransport` | protocol | `BicTermCore/Sources/BicTermCore/Transport/TerminalTransport.swift` | transport seam |
| `HerdrClient` | actor | `HerdrClientCore/HerdrClient.swift` | workspace handshake/surfaces |
| `herdr_client_*` | C ABI | `Vendor/herdr/herdr-ios-ffi/src/abi.rs` | Rust exports |

Reference centrality: not measured (no codegraph index; Swift LSP not wired in this environment).

## CONVENTIONS
- `project.yml` is the ONLY Xcode project source of truth — run `xcodegen generate` after editing. `BicTerm.xcodeproj` is untracked (only its SwiftPM `Package.resolved` pin is tracked).
- Source `scripts/env-local-caches.sh` before any cargo/swift/xcodebuild — forces repo-local caches (containment rule above).
- Build/test scripts honor env overrides: `DEST_OVERRIDE`, `DERIVED_DATA`, `ONLY_TESTING`, `EVIDENCE_LOG`.
- Test scope discipline: during development, run ONLY the tests covering the changed area (`ONLY_TESTING=<suite>` per script, or a direct `xcodebuild` with repeated `-only-testing:` flags when spanning targets). Full `scripts/test-core.sh` + `scripts/test-ui.sh` runs are a final pre-release gate, not a per-change gate. Never burn a multi-hour full-suite run on an unrelated small change.
- Swift 6 strict concurrency in every target (`SWIFT_VERSION "6.0"`).
- Helper frameworks are `MACH_O_TYPE=staticlib`, link-only (`embed: false`) — never embed.
- Vendored-fork patches are recorded in patch docs (e.g. `Vendor/SwiftTerm/BICTERM-PATCH.md`); update the doc with every fork hunk.
- Agents commit completed features themselves (user directive): follow the git-commits skill — atomic Conventional Commits, explicit path staging (never `git add -A`/`git add .`), review `git diff --cached` before every commit, leave others' in-flight work untouched, never push without explicit request.

## ANTI-PATTERNS (THIS PROJECT)
- No SwiftUI/UIKit imports in BicTermCore — layering is enforced.
- No RSA keys, no keyboard-interactive auth (NIOSSH has no client for it — by design).
- Never log secrets; Keychain / Secure Enclave only.
- herdr protocol codec stays in Rust — never reimplement in Swift.
- `HerdrCoreC/include/HerdrCore.h` is cbindgen-generated — never hand-edit.
- Never hand-edit or commit `BicTerm.xcodeproj`.
- Never use pty/device-node APIs (`openpty`, `/dev/ptmx`) or `getpwuid`-based `$HOME` in app or vendored code — sandbox-denied on device; the simulator does not enforce the sandbox. Verified matrix and design rules: `Docs/DEVICE-SANDBOX.md`.
- OSC 52 remote clipboard writes follow the app-side hardened policy (fork hunk 11 surfaces a typed `ClipboardWriteRequest`; the app applies the foreground gate, 100 KiB cap, default-ON Settings toggle, and attribution toast). OSC 52 read/query stays denied unconditionally under every flag; paste remains a local user action only.
- herdr remote install follows the app-side hardened policy: the consent-gated `HerdrRemoteInstaller` offers the pinned, sha256-verified herdr release for the missing-binary case only (never replace/upgrade, no sudo or package managers, `$HOME/.local/bin`); `HerdrInstallBoundaryTests` enforces the vocabulary, sequence-confinement, and reachability boundary, and the probe itself stays read-only.

## UNIQUE STYLES
- Partial `BicTerm/Info.plist` via xcodegen `info:` block for iPad orientation declaration (`~ipad` keys can't be `INFOPLIST_KEY_` settings — xcodebuild silently drops them). Don't hand-edit the plist; edit `project.yml`.
- SSH fixtures: two sshd instances (12222 direct, 12223 jump) + Python UDS forwarder; `fixtures-up.sh` is idempotent via anchored sed (keep the trailing slash).
- Linker anchor `-u _herdr_client_create` keeps the headerless HerdrCore xcframework objects in the app binary.

## COMMANDS
```bash
source scripts/env-local-caches.sh     # ALWAYS first
scripts/build-herdr-core.sh            # fresh clone: Rust FFI xcframework BEFORE package resolution
xcodegen generate                      # after any project.yml edit / fresh clone
xcodebuild -project BicTerm.xcodeproj -scheme BicTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build-artifacts/DerivedData/main build
scripts/fixtures-up.sh                 # sshd fixtures (idempotent)
scripts/test-core.sh                   # unit/integration (needs fixtures up)
scripts/test-ui.sh                     # UI tests
scripts/check-isolation.sh             # module-isolation check (BicTermCore layering)
```

## NOTES
- `HerdrCore.xcframework` is arm64-only: a generic simulator destination builds x86_64 → link failure. ALWAYS name a simulator.
- Fresh clone order: `build-herdr-core.sh` → `xcodegen generate` → build (package resolution needs the xcframework present).
- herdr fixture servers use the pinned prebuilt release binary (`scripts/herdr-server-fetch.sh`, sha256-verified; never built from source), so live fixture handshake tests run without a toolchain; golden-frame replay covers the no-fixture cases. zig 0.16.0 is only needed to regenerate the vendored libghostty-vt artifact (`scripts/herdr-vt-build.sh`).
- Coder/AGPL tailnet support was removed upstream (`ee9956e`); `CODER_WORKSPACE_SSH_PROTOCOL_SPEC.md` remains as historical spec only — do not resurrect Coder patterns from it.
- Device vs simulator sandbox behavior differs (openpty EPERM, container-root write denied, getpwuid escapes the container): probed facts, design rules, and the re-probe recipe live in `Docs/DEVICE-SANDBOX.md`.
- Feature validation is simulator-only. Physical pointer hover/wheel, hardware-keyboard chords (⌘N/⌘W/⌘]/⌘[/⌘, are verified at the routing level only), and other device-only behaviors remain pending separate device authorization.
