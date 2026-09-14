#!/bin/bash
# herdr-embed-core.sh — builds HerdrEmbed.xcframework from the herdr-ios-embed
# static library (the in-process real herdr TUI client, plan herdr-embed T4)
# for aarch64-apple-ios + aarch64-apple-ios-sim, and fails loudly when the
# committed clang-module header (HerdrEmbedC/include/HerdrEmbed.h) drifts from
# the cbindgen ABI. Mirrors build-herdr-core.sh; repo-local outputs only.
#
# The working copy (.build-artifacts/herdr-embed) is bootstrapped via
# herdr-embed-prepare.sh WITHOUT its build proof when absent; run that script
# directly for the full patch/build proof. The simulator slice needs a
# libghostty-vt.a for aarch64-ios-simulator — built on demand by
# scripts/herdr-embed-vt-sim.sh rules below (herdr-vt-build.sh).
#
# Profile: --release with debug=2 DWARF (herdr-ios-embed [profile.release])
# so each slice archives a dSYM for crash symbolication (plan T8), the same
# stub-dylib + dsymutil pattern as build-herdr-core.sh.
#
# Idempotent: re-runs reuse cargo's target cache and re-assemble the
# xcframework. Prerequisite for building the BicTerm app (next to
# build-herdr-core.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env-local-caches.sh"
export RUSTUP_HOME="$ROOT/.build-artifacts/rustup"
export PATH="$ROOT/.build-artifacts/tools/bin:$PATH"

LOG="$ROOT/.sisyphus/evidence/herdr-embed-core.log"
mkdir -p "$ROOT/.sisyphus/evidence"

WORK="$ROOT/.build-artifacts/herdr-embed"
VT_LIB="$WORK/vendor/libghostty-vt/zig-out/lib/libghostty-vt.a"
VT_DEVICE="$ROOT/Vendor/herdr/embed/libghostty-vt/aarch64-ios/libghostty-vt.a"
VT_SIM="$ROOT/.build-artifacts/herdr-vt/aarch64-ios-simulator/libghostty-vt.a"
EMBED_CRATE="$ROOT/Vendor/herdr/herdr-ios-embed"
OUT="$ROOT/.build-artifacts/herdr"
XCF="$OUT/HerdrEmbed.xcframework"
DSYM="$OUT/embed-dsym"

if [ ! -f "$WORK/src/lib.rs" ]; then
    echo "== bootstrapping patched working copy (prepare, no build proof)"
    HERDR_EMBED_SKIP_BUILD=1 HERDR_EMBED_SKIP_FFI=1 "$ROOT/scripts/herdr-embed-prepare.sh"
fi
test -f "$VT_DEVICE" || { echo "missing device libghostty-vt.a" >&2; exit 1; }
if [ ! -f "$VT_SIM" ]; then
    echo "== building simulator libghostty-vt.a (aarch64-ios-simulator)"
    HERDR_VT_TARGETS=aarch64-ios-simulator "$ROOT/scripts/herdr-vt-build.sh"
fi
test -f "$VT_SIM" || { echo "missing $VT_SIM" >&2; exit 1; }

export HERDR_LIBGHOSTTY_VT_PREBUILT=1
cd "$EMBED_CRATE"

echo "== embed staticlib: aarch64-apple-ios (release, bicterm-transport)"
cargo build --locked --release --features bicterm-transport --target aarch64-apple-ios
DEVICE_A="$CARGO_TARGET_DIR/aarch64-apple-ios/release/libherdr_ios_embed.a"
test -s "$DEVICE_A" || { echo "device staticlib missing" >&2; exit 1; }

echo "== embed staticlib: aarch64-apple-ios-sim (release, bicterm-transport)"
# The patched build.rs links whatever .a sits at the vendored zig-out path for
# the requested target; swap the simulator slice in for this build, then put
# the device slice back so the working copy stays device-consistent.
cp "$VT_DEVICE" "$VT_LIB"
trap 'cp "$VT_DEVICE" "$VT_LIB"' EXIT
cp "$VT_SIM" "$VT_LIB"
cargo build --locked --release --features bicterm-transport --target aarch64-apple-ios-sim
SIM_A="$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libherdr_ios_embed.a"
test -s "$SIM_A" || { echo "simulator staticlib missing" >&2; exit 1; }
cp "$VT_DEVICE" "$VT_LIB"
trap - EXIT
cd "$ROOT"

echo "== assembling $XCF (headerless; clang module lives in HerdrEmbedC)"
rm -rf "$XCF"
mkdir -p "$OUT/embed-device" "$OUT/embed-simulator"
cp "$DEVICE_A" "$OUT/embed-device/HerdrEmbed.a"
cp "$SIM_A" "$OUT/embed-simulator/HerdrEmbed.a"

# dSYM archive for crash symbolication (debug=2 DWARF in the release
# profile, plan T8). dsymutil needs a linked debug map, so each slice's
# archive is linked into a throwaway stub dylib that references the ABI
# entry point; the stub never ships, its dSYM carries the Rust DWARF
# (same pattern as build-herdr-core.sh).
mkdir -p "$DSYM/device" "$DSYM/simulator" "$ROOT/.scratch/tmp"
for slice in device simulator; do
    sdk_flag="--sdk iphoneos"
    min_flag="-miphoneos-version-min=18.0"
    if [ "$slice" = "simulator" ]; then
        sdk_flag="--sdk iphonesimulator"
        min_flag="-mios-simulator-version-min=18.0"
    fi
    cat > "$DSYM/$slice/stub.c" <<'EOF'
struct herdr_embed;
struct HerdrEmbedResult;
struct herdr_embed *herdr_embed_start(const void *config,
                                      struct HerdrEmbedResult *error_out);
void herdr_embed_dsym_link_stub(void) {
    herdr_embed_start(0, 0);
}
EOF
    (cd "$DSYM/$slice" && xcrun $sdk_flag clang -arch arm64 $min_flag \
        -dynamiclib stub.c "$OUT/embed-$slice/HerdrEmbed.a" -o stub.dylib)
    xcrun dsymutil "$DSYM/$slice/stub.dylib" \
        -o "$DSYM/$slice/HerdrEmbed.$slice.dSYM"
    rm -f "$DSYM/$slice/stub.dylib" "$DSYM/$slice/stub.c"
done

xcodebuild -create-xcframework \
    -library "$OUT/embed-device/HerdrEmbed.a" \
    -library "$OUT/embed-simulator/HerdrEmbed.a" \
    -output "$XCF"

echo "== header drift check (HerdrEmbedC/include/HerdrEmbed.h)"
mkdir -p "$ROOT/.scratch/tmp"
"$ROOT/.build-artifacts/tools/bin/cbindgen" "$EMBED_CRATE" --crate herdr-ios-embed \
    --config "$EMBED_CRATE/cbindgen.toml" -o "$ROOT/.scratch/tmp/HerdrEmbed.h"
test -s "$ROOT/.scratch/tmp/HerdrEmbed.h"
if ! cmp -s "$ROOT/.scratch/tmp/HerdrEmbed.h" "$ROOT/HerdrEmbedC/include/HerdrEmbed.h"; then
    cp "$ROOT/.scratch/tmp/HerdrEmbed.h" "$ROOT/HerdrEmbedC/include/HerdrEmbed.h"
    echo "ERROR: HerdrEmbed.h drifted from the generated ABI; committed copy updated — review and re-run" >&2
    exit 1
fi
rm -f "$ROOT/.scratch/tmp/HerdrEmbed.h"

echo "== symbol audit"
test -d "$XCF/ios-arm64" || { echo "missing ios-arm64 slice" >&2; exit 1; }
test -d "$XCF/ios-arm64-simulator" || { echo "missing ios-arm64-simulator slice" >&2; exit 1; }
test -d "$DSYM/device/HerdrEmbed.device.dSYM" ||
    { echo "missing device dSYM" >&2; exit 1; }
test -d "$DSYM/simulator/HerdrEmbed.simulator.dSYM" ||
    { echo "missing simulator dSYM" >&2; exit 1; }
for slice in ios-arm64 ios-arm64-simulator; do
    # nm exits nonzero on precompiled rust-std members (LLVM bitcode); only
    # the ABI + vt symbols matter (same pattern as build-herdr-core.sh).
    symbols="$(nm "$XCF/$slice/HerdrEmbed.a" 2>/dev/null || true)"
    grep -q "_herdr_embed_start" <<<"$symbols" ||
        { echo "embed ABI missing from $slice" >&2; exit 1; }
    grep -q "_ghostty_terminal_vt_write" <<<"$symbols" ||
        { echo "libghostty-vt symbols missing from $slice" >&2; exit 1; }
done

echo "BUILD SUCCESS: $XCF (device+simulator, release DWARF, dSYMs, headerless)"
