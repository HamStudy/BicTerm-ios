# DEPENDENCIES.md — BicTerm dependency & license inventory

Review date: 2026-09-03 (task T3 key layer); amended 2026-09-04 (task T8 vendored swift-nio-ssh fork)
Policy: App Store distribution requires GPL/LGPL-free dependencies.
All entries below use permissive Apache-2.0, MIT, ISC, or BSD-3-Clause licenses — **verdict: GO**.

## Direct dependencies (pinned exact)

| Name | Pinned version | License | Source | Notes |
|---|---|---|---|---|
| SwiftTerm | 1.20.0 (`v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`) | MIT | https://github.com/migueldeicaza/SwiftTerm | Terminal emulation/view; consumed via the vendored fork below (app target only, never inside BicTermCore). Removed from `project.yml`'s remote `packages:` section; local `Vendor/SwiftTerm` path is used. |

Note (2026-09-04, task T8): swift-nio-ssh is NO LONGER a remote pin — BicTermCore
now depends on the vendored fork below via a local path dependency
(`Vendor/swift-nio-ssh`). Upstream 0.15.0 cannot express OpenSSH agent
forwarding (confirmed: outbound `auth-agent-req@openssh.com` →
`ChannelError.operationUnsupported` at SSHChildChannel.swift:427; inbound
`auth-agent@openssh.com` channel open → `NIOSSHError.unknownPacketType` at
SSHMessages.swift:905-906, which kills the connection).

## Vendored source dependencies

| Name | Pinned revision | License | Source | Notes |
|---|---|---|---|---|
| swift-nio-ssh (NIOSSH), BicTerm fork | 0.15.0 (`3ec281496f28a3b6581afd946b759e2642f5cd8d`) + 12 `BICTERM-PATCH` hunks | Apache-2.0 | https://github.com/apple/swift-nio-ssh | Vendored at `Vendor/swift-nio-ssh` (2026-09-04, task T8); the 12 marked hunks add OpenSSH agent channel/request parsing and serialization plus outbound agent-request emission; LICENSE.txt retained; upstream PR candidate |
| SwiftTerm, BicTerm fork | 1.20.0 (`v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`) + keyboard test-seam access | MIT | https://github.com/migueldeicaza/SwiftTerm | Vendored at `Vendor/SwiftTerm` (2026-09-06, task T12; hunks completed 2026-09-07); 5 additive hunks documented in `Vendor/SwiftTerm/BICTERM-PATCH.md` with inline `BICTERM-PATCH hunk N` markers; LICENSE preserved verbatim; hunks widen `keyRepeat`/`pressesEnded` access and add the `installsSoftwareKeyboard` opt-out (hidden blocker input view + `.causesPageTurn` gating) consumed only by the app's DEBUG UI-test seams; production input paths, timers, and traits are unchanged; upstream PR candidate |
| OpenSSH portable `bcrypt_pbkdf.c` | `7fe3b24c922b7af2d743737f7cf37df61ea06426` | ISC | https://github.com/openssh/openssh-portable | Adapted to CommonCrypto SHA-512 in `CBcryptPBKDF`; original notice retained |
| OpenSSH portable `blowfish.c` / `blf.h` | `7fe3b24c922b7af2d743737f7cf37df61ea06426` | BSD-3-Clause | https://github.com/openssh/openssh-portable | bcrypt PBKDF support only; original notices retained |

## Transitive dependencies (as resolved; see Package.resolved / workspace state)

| Name | Resolved version | License | Source |
|---|---|---|---|
| swift-nio | 2.102.0 | Apache-2.0 | https://github.com/apple/swift-nio.git |
| swift-crypto | 4.5.2 | Apache-2.0 | https://github.com/apple/swift-crypto.git |
| swift-atomics | 1.3.1 | Apache-2.0 | https://github.com/apple/swift-atomics.git |
| swift-collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections.git |
| swift-system | 1.8.1 | Apache-2.0 | https://github.com/apple/swift-system.git |
| swift-asn1 | 1.7.2 | Apache-2.0 | https://github.com/apple/swift-asn1.git |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |

Notes:
- `swift-nio-transport-services` did NOT resolve (only pulled when NIOTransportServices
  product is imported; we currently use NIOSSH → NIOCore only). Re-check this table if
  that product is adopted later.
- `swift-argument-parser` resolves via SwiftTerm's `Termcast` executable target; it is
  not linked into the app binary but is part of the package graph.
- SwiftTerm 1.20.0 ships a build-tool plugin (`SwiftTermBuildInfoPlugin`); headless
  builds require `-skipPackagePluginValidation` (see `scripts/test-ui.sh`).
- SwiftTerm 1.20.0 compiles Metal shaders; Xcode 26 requires the on-demand
  Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) — installed 2026-09-04.

**Verdict: GO** — all licenses are permissive, App-Store compatible, and GPL/LGPL-free.
