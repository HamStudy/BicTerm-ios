# Vendor Knowledge Base

## OVERVIEW
Three vendored forks, referenced by path from `project.yml` / `BicTermCore/Package.swift` (never by remote version pin: the fork on disk is the source of truth).

## WHERE TO LOOK
| Fork | Version / pin | License | Key files | Fork patches |
|------|---------------|---------|-----------|--------------|
| SwiftTerm | 1.20.0 (`v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`) | MIT | `SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift` | 11 hunks (1-5 debug UI-test seams, 6-7 mouse/selection repair, 8 hosted accessory fallback, 9 local selection reliability, 10 reconnect mode reset, 11 OSC 52 typed write surface), inline `BICTERM-PATCH hunk N` markers, documented in `SwiftTerm/BICTERM-PATCH.md` |
| swift-nio-ssh | 0.15.0 (commit `3ec281496f28a3b6581afd946b759e2642f5cd8d`) | Apache-2.0 | `swift-nio-ssh/Sources/NIOSSH/` | 12 hunks (agent forwarding), documented in `swift-nio-ssh/BICTERM-PATCH.md` |
| herdr | v0.9.0 (commit `b99002ac99b09e00b4ca692436cb15a6b0d676f1`) | Apache-2.0 | `herdr/herdr-ios-ffi/src/abi.rs`, `herdr/herdr-protocol/` | extraction/provenance in `herdr/PROVENANCE.md`, `herdr/MODIFICATIONS.md` |

Per-fork details:

- **SwiftTerm** (app target only; `BicTermCore` never links it). Hunks 1-5: DEBUG UI-test seams (keyRepeat/pressesEnded access widening, `installsSoftwareKeyboard` opt-out), production-inert. Hunks 6-7: mouse/selection repair (X10 gates, SGR 1006 press/drag/hover/wheel routing, local selection/copy/paste with bracketed-paste framing). Hunk 8: `hostedAccessory` fallback so the app-hosted TerminalAccessory feeds sticky ctrl. Hunk 9: local selection reliability (feed preservation, drag pivot, Option bypass, menu focus). Hunk 10: additive `resetSessionModes()` for reconnect. Hunk 11: typed `ClipboardWriteRequest` + `oscClipboardWriteRequest` delegate so the app applies its OSC 52 policy at one decision point (foreground, 100 KiB cap, default-ON Settings toggle, attribution toast); read/query stays routed through the default-deny `clipboardRead`. Fork tests: `SwiftTerm/Tests/SwiftTermTests/BicTermMouseTests.swift`.
- **swift-nio-ssh**: adds `auth-agent@openssh.com` channel open and `auth-agent-req@openssh.com` request parse/serialize plus outbound emission. Consumed by `BicTermCore` via `.package(path: "../Vendor/swift-nio-ssh")`.
- **herdr** (Rust): `herdr-ios-ffi/src/abi.rs` exports the `herdr_client_*` C ABI consumed by HerdrClientCore. `herdr-protocol/tests/fixtures/golden/` holds committed golden frames (client-*.bin, server-*.bin) replayed by HerdrClientCoreTests. `check.sh` runs cargo-deny + jq license/SBOM policy. `THIRD_PARTY_NOTICES.md` is bundled into the app target via `project.yml`. Fuzz targets under `herdr-ios-ffi/fuzz/` (nightly, optional, `run-fuzz.sh`).

## CONVENTIONS
- Any change to a vendored fork must be minimal and additive where possible.
- Record every fork hunk in the fork's patch doc, hunk by hunk, with an inline `BICTERM-PATCH hunk N` marker in the source.
- Keep license files verbatim; keep `THIRD_PARTY_NOTICES.md` and the root `DEPENDENCIES.md` inventory accurate when dependencies shift.
- Rebase instructions live inside each patch doc; follow them rather than re-deriving.

## ANTI-PATTERNS
- Never silently edit fork files; an undocumented hunk breaks mechanical rebasing.
- Never upgrade or rebase a fork casually; re-validate the patch doc hunk by hunk against the new upstream tag first.
- Never reimplement the herdr Rust codec in Swift; the protocol core stays in Rust.
- Never replace the local path reference with a remote SwiftPM pin.
- Never brew-install SwiftTerm or swift-nio-ssh equivalents; the forks under `Vendor/` are what builds.

## NOTES
- SwiftTerm fork regression tests cover exact SGR press/release/drag/hover/wheel bytes; run them after touching hunks 6-7.
- OSC 52 remote clipboard writes follow the app-side hardened policy (fork hunk 11 surfaces a typed `ClipboardWriteRequest`; the app applies the foreground gate, 100 KiB cap, Settings toggle, and attribution toast). OSC 52 read/query stays denied unconditionally under every flag; paste remains a local user action only.
- SwiftTerm ships the `SwiftTermBuildInfoPlugin` build-tool plugin and compiles Metal shaders; see root `DEPENDENCIES.md` notes before tweaking build settings.
- herdr `check.sh` needs cargo-deny and jq; the fuzz pass needs a nightly toolchain and is not part of the normal build/test chain.
- Upstream PR candidacy: the nio-ssh agent hunks and SwiftTerm hunks 1-5 are written to be upstreamable; keep them additive and marked.
