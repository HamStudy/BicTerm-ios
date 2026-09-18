# Vendored libghostty-vt static library (iOS)

`aarch64-ios/libghostty-vt.a` is the vendored Ghostty VT static library for
iOS device (arm64, min OS 17), built from the pristine herdr-upstream source
at `Vendor/herdr/upstream/vendor/libghostty-vt` (upstream vendoring commit
`44f2a44df7e8c4a0c6df3f7d872ef3d7ead88e51`, version `1.3.2-HEAD-+44f2a44df`,
from `vendor/libghostty-vt.vendor.json`; herdr v0.9.1).

| Property | Value |
| --- | --- |
| Target | `aarch64-ios` (upstream `Config.osVersionMinLibVt`; LC_BUILD_VERSION platform iOS) |
| Archive | zig 0.16.0 ar output, links with Apple ld as-is (the 0.15.x unaligned-member defect is gone) |
| Exports | 199 `ghostty_*` C-ABI symbols — exactly the set declared in upstream `src/ghostty/bindings.rs` |
| sha256 | `3bc91660aa616719423302d91c8550b8c5a5a9d5cad145ab24dcf714b56256a8` |
| Size | 9.4 MB (below the 10 MB commit threshold, hence vendored) |

Build configuration is upstream's own `zig build -Demit-lib-vt` invocation:
`ReleaseFast`, `simd` off (scalar fallbacks; identical C ABI surface, no C++
SIMD dependencies), `c_abi` on. compiler-rt/ubsan-rt are not bundled — rust's
`compiler-builtins` (herdr binary) and the Apple toolchain (app) provide
those symbols.

## Regenerating

```bash
scripts/herdr-vt-build.sh   # rebuilds .build-artifacts/herdr-vt/aarch64-ios/
                            # needs network once for zig 0.16.0 + the pinned deps
```

herdr 0.9.1's vendored libghostty-vt requires zig 0.16.0
(`minimum_zig_version` in its build.zig.zon; enforced by herdr's build.rs).
zig 0.16.0 also fixed the macOS 26 host-link bug that forced the previous
release's hand-materialized `zig build-lib` replay, so the script now runs
upstream's own build graph on a scratch copy of the vendored tree; see the
script header. A simulator slice (`aarch64-ios-simulator`) and the host
slice (`aarch64-macos`, needed by the embed crate's host-side harness tests)
build on demand:

```bash
HERDR_VT_TARGETS="aarch64-ios aarch64-ios-simulator aarch64-macos" scripts/herdr-vt-build.sh
```

Verification for any archive: `nm -gU <archive>` lists the 199 `ghostty_*`
symbols (diff against `grep -oE 'fn (ghostty_[a-z_0-9]+)' src/ghostty/bindings.rs`
at the pinned herdr ref — they must match exactly).

The herdr-upstream tree (`Vendor/herdr/upstream/**`) is never written by
the build; all scratch lives under `.build-artifacts/`.
