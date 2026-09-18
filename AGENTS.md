# Agent Instructions

## NEVER Write Outside the Project

**The first and strongest default rule: agents and every subprocess they launch must keep every controllable write inside `/Users/richard/code/BicTerm-ios`.** Changing the working directory, invoking another tool, or delegating work does not weaken or relocate this boundary. The only exception is the narrow Apple tooling exception below.

- Never select `/tmp`, `/private/tmp`, `$HOME`, home-directory caches, Downloads, Desktop, or any other external scratch, build, test, log, result, cache, or evidence path.
- Treat DerivedData, result bundles, logs, screenshots, temporary files, package/cache overrides, evidence, generated artifacts, downloads, and tool metadata as agent-controlled outputs subject to this rule.
- Before running any command that can write, inspect every explicit and implicit output, cache, temporary, build, result, screenshot, log, and evidence path and confirm it resolves within `/Users/richard/code/BicTerm-ios`.
- Override tools whose defaults write externally. Use repository-local destinations such as `.build-artifacts/DerivedData/<task>`, `.build-artifacts/xcresults/`, `.sisyphus/evidence/`, and `.scratch/`.
- Apple Xcode and CoreSimulator tooling may perform incidental system-managed writes outside the repository only when those writes are inherent, cannot be redirected, and the tooling is required for build, test, or simulator QA. This permits only Apple-created simulator/device state and unavoidable Apple tool metadata; it does not permit agents to choose external output, cache, log, screenshot, result, temporary, package, evidence, or scratch paths.
- Outside that narrow exception, do not run a command when all of its writes cannot be redirected into the project or when containment cannot be guaranteed. The exception does not apply to non-Apple tools.
- Ensure scripts, child processes, build systems, test runners, simulators, package managers, and other delegated tools obey the same boundary.

No convenience, default behavior, debugging need, or evidence requirement permits any exception beyond the unavoidable Apple tooling writes defined above.

---

# PROJECT KNOWLEDGE BASE

**Generated:** 2026-09-11 · **Commit:** 7e06a3c · **Branch:** main

## OVERVIEW
iOS 18+ SSH terminal (SwiftUI, Swift 6 strict concurrency) on vendored SwiftNIO SSH + SwiftTerm forks; also a herdr workspace client via a Rust FFI core. Xcode project is Xcodegen-generated; platform-agnostic logic lives in a SwiftPM core package.

## STRUCTURE
```
BicTerm-ios/
├── BicTerm/            # iOS app (SwiftUI): Terminal, Herdr, Sessions, Connections, Keys, Agent, Design
├── BicTermCore/        # SwiftPM core — SSH/transport/session logic, no SwiftUI/UIKit
├── HerdrClientCore/    # Swift actor wrapper over the herdr Rust FFI (3 files, framework target)
├── HerdrCoreC/         # Clang-module host exposing cbindgen HerdrCore.h (stub.c only)
├── Fixtures/           # Local test fixtures: sshd (ports 12222/12223), UDS forwarder, herdr, keys
├── Vendor/             # Vendored forks: SwiftTerm, swift-nio-ssh, herdr (Rust)
├── scripts/            # Build/test/fixture harness (7 shell scripts, env-override contract)
├── Docs/               # Design/traceability docs
└── project.yml         # Xcodegen spec — source of truth for the Xcode project
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| App entry / scenes | `BicTerm/App/BicTermApp.swift` | @main, 3 WindowGroups |
| Session lifecycle, reconnect | `BicTerm/Sessions/SessionStore.swift` | registry + toolbar state |
| Terminal view bridge | `BicTerm/Terminal/TerminalRepresentable.swift` | SwiftTerm ↔ SwiftUI |
| Terminal toolbar strip | `BicTerm/Terminal/TerminalToolbar.swift` | esc/ctrl/tab/arrows, GCKeyboard heuristic |
| SSH transport, ProxyJump, agent | `BicTermCore/Sources/BicTermCore/SSH/` | NIO SSH based |
| Transport abstraction seam | `BicTermCore/Sources/BicTermCore/Transport/TerminalTransport.swift` | SSH is one conformer |
| herdr UI (panes/surfaces) | `BicTerm/Herdr/` | largest app subdir (19 files) |
| herdr client core | `HerdrClientCore/HerdrClient.swift` | actor over C ABI |
| Rust FFI exports | `Vendor/herdr/herdr-ios-ffi/src/abi.rs` | `herdr_client_*` |
| Test fixtures | `Fixtures/` + `scripts/fixtures-up.sh` | sshd 12222/12223 |
| UI tests | `BicTermUITests/` | incl. FreeformResize, TerminalToolbar |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BicTermApp` | @main App | `BicTerm/App/BicTermApp.swift` | scenes, 3 WindowGroups |
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

## ANTI-PATTERNS (THIS PROJECT)
- No SwiftUI/UIKit imports in BicTermCore — layering is enforced.
- No RSA keys, no keyboard-interactive auth (NIOSSH has no client for it — by design).
- Never log secrets; Keychain / Secure Enclave only.
- herdr protocol codec stays in Rust — never reimplement in Swift.
- `HerdrCoreC/include/HerdrCore.h` is cbindgen-generated — never hand-edit.
- Never hand-edit or commit `BicTerm.xcodeproj`.
- Never use pty/device-node APIs (`openpty`, `/dev/ptmx`) or `getpwuid`-based `$HOME` in app or vendored code — sandbox-denied on device; the simulator does not enforce the sandbox. Verified matrix and design rules: `Docs/DEVICE-SANDBOX.md`.
- OSC 52 remote clipboard writes follow the app-side hardened policy (fork hunk 11 surfaces a typed `ClipboardWriteRequest`; the app applies the foreground gate, 100 KiB cap, default-ON Settings toggle, and attribution toast). OSC 52 read/query stays denied unconditionally under every flag; paste remains a local user action only.

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
scripts/check-isolation.sh             # containment verifier
```

## NOTES
- `HerdrCore.xcframework` is arm64-only: a generic simulator destination builds x86_64 → link failure. ALWAYS name a simulator.
- Fresh clone order: `build-herdr-core.sh` → `xcodegen generate` → build (package resolution needs the xcframework present).
- Live herdr-server fixture blocked: zig 0.15.x fails to link on macOS 26; herdr tests use committed-frame replay.
- Coder/AGPL tailnet support was removed upstream (`ee9956e`); `CODER_WORKSPACE_SSH_PROTOCOL_SPEC.md` remains as historical spec only — do not resurrect Coder patterns from it.
- Device vs simulator sandbox behavior differs (openpty EPERM, container-root write denied, getpwuid escapes the container): probed facts, design rules, and the re-probe recipe live in `Docs/DEVICE-SANDBOX.md`.
