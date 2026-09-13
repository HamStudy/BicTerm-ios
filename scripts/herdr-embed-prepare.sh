#!/bin/bash
# herdr-embed-prepare.sh — materialize the patched herdr embed working copy.
#
# Copies the pristine upstream checkout (Vendor/herdr/upstream, pinned at
# b99002ac) into .build-artifacts/herdr-embed/, applies the patch series from
# Vendor/herdr/embed-patches/ in order, and installs a libghostty-vt.a so the
# tree links without zig (see Vendor/herdr/EMBED-PATCHES.md).
#
# Env overrides:
#   HERDR_EMBED_DIR            output dir (default .build-artifacts/herdr-embed)
#   HERDR_EMBED_GHOSTTY_VT_A   path to a real libghostty-vt.a; default is the
#                              committed link stub (LINK STUB ONLY — it cannot
#                              parse VT; task T2 replaces it with a real build)
#   HERDR_EMBED_SKIP_BUILD     set 1 to skip the post-apply iOS build proof
#   HERDR_EMBED_SKIP_FFI       set 1 to skip the embed FFI build proof (T3)
#
# On success the tree is build-proven with:
#   cargo build --locked --target aarch64-apple-ios
#   cargo build --locked --features bicterm-transport --target aarch64-apple-ios
# both with HERDR_LIBGHOSTTY_VT_PREBUILT=1 (repo-local caches, pinned 1.96.1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env-local-caches.sh"
export RUSTUP_HOME="$ROOT/.build-artifacts/rustup"

UPSTREAM="$ROOT/Vendor/herdr/upstream"
PATCHES="$ROOT/Vendor/herdr/embed-patches"
OUT="${HERDR_EMBED_DIR:-$ROOT/.build-artifacts/herdr-embed}"
BASE="b99002ac99b09e00b4ca692436cb15a6b0d676f1"

test -d "$UPSTREAM/.git" || { echo "missing $UPSTREAM checkout" >&2; exit 1; }
test -d "$PATCHES" || { echo "missing $PATCHES" >&2; exit 1; }

echo "== extracting pristine upstream $BASE"
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$UPSTREAM" archive "$BASE" | tar -x -C "$OUT"
# Make the working copy its own git repo: `git apply` run from a directory
# that git resolves as a SUBDIRECTORY of an enclosing repo (this path is
# inside the BicTerm work tree) silently skips toplevel-relative patches
# with exit 0. At a repo root the prefix is empty and patches apply.
git -C "$OUT" init -q
git -C "$OUT" config user.name "herdr-embed-prepare"
git -C "$OUT" config user.email "embed@bicterm.invalid"
git -C "$OUT" add -A
git -C "$OUT" commit -qm "base: herdr $BASE"

echo "== applying patch series"
shopt -s nullglob
patch_files=("$PATCHES"/[0-9]*.patch)
shopt -u nullglob
test ${#patch_files[@]} -gt 0 || { echo "no patches in $PATCHES" >&2; exit 1; }
for patch in "${patch_files[@]}"; do
    echo "-- $(basename "$patch")"
    git -C "$OUT" apply --check "$patch"
    git -C "$OUT" apply "$patch"
done
echo "applied ${#patch_files[@]} patches"
git -C "$OUT" diff --stat | tail -1

# Sentinel check: git apply can only fail loudly here, but verify the
# series actually landed before trusting any build below.
grep -q "HERDR_LIBGHOSTTY_VT_PREBUILT" "$OUT/build.rs" ||
    { echo "patch 0001 did not land" >&2; exit 1; }
grep -q "wait_client_stream_readable" "$OUT/src/platform/fallback.rs" ||
    { echo "patch 0002 did not land" >&2; exit 1; }
test -f "$OUT/src/lib.rs" ||
    { echo "patch 0003 did not land" >&2; exit 1; }
grep -q "bicterm-transport" "$OUT/Cargo.toml" ||
    { echo "patch 0004 did not land" >&2; exit 1; }

echo "== installing libghostty-vt.a"
VT_DIR="$OUT/vendor/libghostty-vt/zig-out/lib"
mkdir -p "$VT_DIR"
# T3 default: the REAL committed aarch64-ios archive (Vendor/herdr/embed/,
# plan task 2). The link stub remains available via HERDR_EMBED_GHOSTTY_VT_A
# for reproducing T1's stub-linked build proof.
VT_A="${HERDR_EMBED_GHOSTTY_VT_A:-$ROOT/Vendor/herdr/embed/libghostty-vt/aarch64-ios/libghostty-vt.a}"
test -f "$VT_A" || { echo "missing $VT_A" >&2; exit 1; }
cp "$VT_A" "$VT_DIR/libghostty-vt.a"
file "$VT_DIR/libghostty-vt.a"

if [ "${HERDR_EMBED_SKIP_BUILD:-0}" = "1" ]; then
    echo "PREPARED: $OUT (build proof skipped)"
    exit 0
fi

echo "== build proof (aarch64-apple-ios, pinned toolchain, prebuilt libghostty-vt)"
export HERDR_LIBGHOSTTY_VT_PREBUILT=1
# git-archive extraction writes commit-date mtimes, which are OLDER than any
# warm target-dir fingerprints; cargo would then reuse stale artifacts and
# skip compiling this tree entirely. Force a real compile of the workspace
# crate (shared dependency artifacts stay).
cargo clean --manifest-path "$OUT/Cargo.toml" -p herdr
cargo build --locked --manifest-path "$OUT/Cargo.toml" --target aarch64-apple-ios
cargo build --locked --manifest-path "$OUT/Cargo.toml" \
    --features bicterm-transport --target aarch64-apple-ios
BIN="$CARGO_TARGET_DIR/aarch64-apple-ios/debug/herdr"
file "$BIN"

# ---- embed FFI build proof (plan task 3) ------------------------------------
# Builds Vendor/herdr/herdr-ios-embed against the patched working copy for
# aarch64-apple-ios, both feature variants, and regenerates the committed
# cbindgen header with a loud drift check (build-herdr-core.sh pattern).
if [ "${HERDR_EMBED_SKIP_FFI:-0}" = "1" ]; then
    echo "PREPARED AND BUILD-PROVEN: $OUT (embed FFI proof skipped)"
    exit 0
fi

if [ ! -x "$ROOT/.build-artifacts/tools/bin/cbindgen" ]; then
    echo "installing cbindgen repo-locally"
    cargo install --locked --root "$ROOT/.build-artifacts/tools" cbindgen
fi
CBINDGEN="$ROOT/.build-artifacts/tools/bin/cbindgen"

EMBED_CRATE="$ROOT/Vendor/herdr/herdr-ios-embed"
HEADER="$EMBED_CRATE/include/HerdrEmbed.h"
echo "== embed FFI build proof (aarch64-apple-ios, both variants)"
(
    cd "$EMBED_CRATE"
    cargo build --locked --target aarch64-apple-ios
    cargo build --locked --features bicterm-transport --target aarch64-apple-ios
)
STATICLIB="$CARGO_TARGET_DIR/aarch64-apple-ios/debug/libherdr_ios_embed.a"
test -s "$STATICLIB" || { echo "embed staticlib missing: $STATICLIB" >&2; exit 1; }
# nm exits nonzero on precompiled rust-std members (LLVM bitcode); only the
# workspace-crate symbols matter, so nm's exit is ignored (same as
# build-herdr-core.sh's audit).
embed_symbols="$(nm "$STATICLIB" 2>/dev/null || true)"
grep -q "_herdr_embed_start" <<<"$embed_symbols" ||
    { echo "embed ABI symbol missing from $STATICLIB" >&2; exit 1; }
grep -q "_ghostty_terminal_vt_write" <<<"$embed_symbols" ||
    { echo "libghostty-vt symbols missing from $STATICLIB" >&2; exit 1; }

echo "== cbindgen header (HerdrEmbed.h)"
mkdir -p "$ROOT/.scratch/tmp"
"$CBINDGEN" "$EMBED_CRATE" --crate herdr-ios-embed \
    --config "$EMBED_CRATE/cbindgen.toml" -o "$ROOT/.scratch/tmp/HerdrEmbed.h"
test -s "$ROOT/.scratch/tmp/HerdrEmbed.h"
if ! cmp -s "$ROOT/.scratch/tmp/HerdrEmbed.h" "$HEADER" 2>/dev/null; then
    if [ -f "$HEADER" ]; then
        cp "$ROOT/.scratch/tmp/HerdrEmbed.h" "$HEADER"
        echo "ERROR: HerdrEmbed.h drifted from the generated ABI; committed copy updated — review and re-run" >&2
        exit 1
    fi
    mkdir -p "$EMBED_CRATE/include"
    cp "$ROOT/.scratch/tmp/HerdrEmbed.h" "$HEADER"
    echo "HerdrEmbed.h generated for the first time — commit it"
fi
rm -f "$ROOT/.scratch/tmp/HerdrEmbed.h"
echo "PREPARED AND BUILD-PROVEN: $OUT (embed FFI ok)"
