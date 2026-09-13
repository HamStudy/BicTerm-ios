# Vendored libghostty-vt static library (iOS)

`aarch64-ios/libghostty-vt.a` is the vendored Ghostty VT static library for
iOS device (arm64, min OS 17), built from the pristine herdr-upstream source
at `Vendor/herdr/upstream/vendor/libghostty-vt` (upstream vendoring commit
`c5a21edfcbc2d5b46540ad91b7980aca31f5f1f3`, version `1.3.2-HEAD-+c5a21edfc`,
from `vendor/libghostty-vt.vendor.json`).

| Property | Value |
| --- | --- |
| Target | `aarch64-ios.17.0` (LC_BUILD_VERSION platform iOS) |
| Archive | Apple `libtool -static` repack (zig's unaligned ar rejected by Apple ld) |
| Exports | 173 `ghostty_*` C-ABI symbols — exactly the set declared in upstream `src/ghostty/bindings.rs` |
| sha256 | `109705d00299c886dda9549ccc84bd8a76ee67228c3cdb37533dfdf2e0a944a7` |
| Size | 6.1 MB (below the 10 MB commit threshold, hence vendored) |

Build configuration mirrors upstream `GhosttyLibVt.initStatic()` for
`-Demit-lib-vt`: `ReleaseFast`, PIC, LLVM backend, `c_abi` on, `simd` off
(scalar fallbacks; identical C ABI surface, no C++ SIMD dependencies).
compiler-rt/ubsan-rt are not bundled — rust's `compiler-builtins` (herdr
binary) and the Apple toolchain (app) provide those symbols.

## Regenerating

```bash
scripts/herdr-vt-build.sh   # rebuilds .build-artifacts/herdr-vt/aarch64-ios/
                            # needs network once for zig 0.15.2 + uucode 0.2.0
```

The script bypasses the `zig build` runner (its host-link is broken on
macOS 26 with zig 0.15.2) by invoking `zig build-lib` directly and
materializing the generated modules itself; see its header for the exact
flags and the documented off-host fallback. A simulator slice
(`aarch64-ios-simulator`) builds on demand:

```bash
HERDR_VT_TARGETS="aarch64-ios aarch64-ios-simulator" scripts/herdr-vt-build.sh
```

Verification for either archive: `nm -gU <archive>` lists the 173
`ghostty_*` symbols; `.sisyphus/evidence/herdr-embed-t2.log` records the
full build, the bindings-symbol diff, and standalone Apple-ld link proofs
for both device and simulator.

The herdr-upstream tree (`Vendor/herdr/upstream/**`) is never written by
the build; all scratch lives under `.build-artifacts/`.
