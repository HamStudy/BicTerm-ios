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
VT_A="${HERDR_EMBED_GHOSTTY_VT_A:-$PATCHES/libghostty-vt.linkstub-aarch64-ios.a}"
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
echo "PREPARED AND BUILD-PROVEN: $OUT"
