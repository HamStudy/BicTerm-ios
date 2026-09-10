#!/bin/bash
# build-herdr-core.sh — builds HerdrCore.xcframework from the vendored Herdr
# Rust client core (herdr-ios-ffi) for aarch64-apple-ios + aarch64-apple-ios-sim,
# generates the C header with cbindgen, archives dSYMs, and assembles the
# xcframework with repo-local outputs only (.build-artifacts/herdr/, gitignored).
#
# Idempotent: wipes and rebuilds its output directory. Fails loudly: full log
# teed to .sisyphus/evidence/phase2-h14-build.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env-local-caches.sh"
export RUSTUP_HOME="$ROOT/.build-artifacts/rustup"
export PATH="$ROOT/.build-artifacts/tools/bin:$PATH"

EVIDENCE="$ROOT/.sisyphus/evidence"
LOG="$EVIDENCE/phase2-h14-build.log"
mkdir -p "$EVIDENCE" "$ROOT/.scratch/tmp"

OUT="$ROOT/.build-artifacts/herdr"
DEVICE="$OUT/device"
SIMULATOR="$OUT/simulator"
DSYM="$OUT/dsym"

if [ ! -x "$ROOT/.build-artifacts/tools/bin/cbindgen" ]; then
    echo "installing cbindgen repo-locally"
    cargo install --locked --root "$ROOT/.build-artifacts/tools" cbindgen
fi
CBINDGEN="$ROOT/.build-artifacts/tools/bin/cbindgen"

build() {
    rm -rf "$OUT"
    mkdir -p "$DEVICE/include" "$SIMULATOR/include" "$DSYM/device" "$DSYM/simulator"

    for triple in aarch64-apple-ios aarch64-apple-ios-sim; do
        cargo build --locked --manifest-path Vendor/herdr/Cargo.toml \
            --profile ios-release --target "$triple" -p herdr-ios-ffi
    done

    "$CBINDGEN" Vendor/herdr --crate herdr-ios-ffi \
        --config Vendor/herdr/herdr-ios-ffi/cbindgen.toml -o "$OUT/include/HerdrCore.h"
    test -s "$OUT/include/HerdrCore.h"
    # The committed header IS the cbindgen contract; fail loudly on drift.
    if ! cmp -s "$OUT/include/HerdrCore.h" "$ROOT/HerdrCoreC/include/HerdrCore.h"; then
        cp "$OUT/include/HerdrCore.h" "$ROOT/HerdrCoreC/include/HerdrCore.h"
        echo "ERROR: HerdrCore.h drifted from the generated ABI; committed copy updated — review and re-run" >&2
        exit 1
    fi

    cp "$CARGO_TARGET_DIR/aarch64-apple-ios/ios-release/libherdr_ios_ffi.a" "$DEVICE/HerdrCore.a"
    cp "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/ios-release/libherdr_ios_ffi.a" "$SIMULATOR/HerdrCore.a"

    # dSYM archive for crash symbolication (debug=2 DWARF in ios-release).
    # dsymutil needs a linked debug map, so each slice's archive is linked
    # into a throwaway stub dylib that references the ABI entry point; the
    # stub never ships, its dSYM carries the Rust DWARF.
    for slice in device simulator; do
        sdk_flag="--sdk iphoneos"
        min_flag="-miphoneos-version-min=18.0"
        if [ "$slice" = "simulator" ]; then
            sdk_flag="--sdk iphonesimulator"
            min_flag="-mios-simulator-version-min=18.0"
        fi
        cat > "$DSYM/$slice/stub.c" <<'EOF'
extern void *herdr_client_create(const void *config, void *error_out);
void herdr_core_dsym_link_stub(void) {
    herdr_client_create(0, 0);
}
EOF
        (cd "$DSYM/$slice" && xcrun $sdk_flag clang -arch arm64 $min_flag \
            -dynamiclib stub.c "$OUT/$slice/HerdrCore.a" -o stub.dylib)
        xcrun dsymutil "$DSYM/$slice/stub.dylib" \
            -o "$DSYM/$slice/HerdrCore.$slice.dSYM"
        rm -f "$DSYM/$slice/stub.dylib" "$DSYM/$slice/stub.c"
    done

    # Headerless on purpose: ProcessXCFramework flattens module maps from
    # every header-carrying xcframework into the shared per-build include
    # dir, and CoderNet.xcframework already owns that slot. The clang module
    # for the ABI lives in the HerdrCoreC target (HerdrCoreC/include).
    xcodebuild -create-xcframework \
        -library "$DEVICE/HerdrCore.a" \
        -library "$SIMULATOR/HerdrCore.a" \
        -output "$OUT/HerdrCore.xcframework"

    verify
}

verify() {
    test -d "$OUT/HerdrCore.xcframework/ios-arm64"
    test -d "$OUT/HerdrCore.xcframework/ios-arm64-simulator"
    # Precompiled rust-std members carry LLVM bitcode the host nm cannot read;
    # only the workspace-crate symbols matter for this audit, so nm's nonzero
    # exit on those members is ignored (ld links them fine — proven by the
    # dSYM stub link and the app Debug build).
    for slice in ios-arm64 ios-arm64-simulator; do
        symbols="$(nm -gU "$OUT/HerdrCore.xcframework/$slice/HerdrCore.a" 2>/dev/null || true)"
        grep -q _herdr_client_create <<<"$symbols"
    done
    grep -q "herdr_client_create" "$ROOT/HerdrCoreC/include/HerdrCore.h"
    test -d "$DSYM/device/HerdrCore.device.dSYM"
    test -d "$DSYM/simulator/HerdrCore.simulator.dSYM"
    echo "BUILD SUCCESS: $OUT/HerdrCore.xcframework (device+simulator, headers, dSYMs)"
}

build 2>&1 | tee "$LOG"
