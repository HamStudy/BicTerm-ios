# DEPENDENCIES.md — BicTerm dependency & license inventory

Review date: 2026-09-04 (task T1 bootstrap)
Policy: App Store distribution requires GPL/LGPL-free dependencies.
All entries below are Apache-2.0 or MIT — **verdict: GO**.

## Direct dependencies (pinned exact)

| Name | Pinned version | License | Source | Notes |
|---|---|---|---|---|
| swift-nio-ssh (NIOSSH) | 0.15.0 (exact) | Apache-2.0 | https://github.com/apple/swift-nio-ssh | SSH transport for BicTermCore; pinned in `BicTermCore/Package.swift` |
| SwiftTerm | 1.20.0 (exactVersion) | MIT | https://github.com/migueldeicaza/SwiftTerm | Terminal emulation/view; pinned in `project.yml` (app target only, never inside BicTermCore) |

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

**Verdict: GO** — all licenses are Apache-2.0/MIT class, App-Store compatible, GPL-free.
