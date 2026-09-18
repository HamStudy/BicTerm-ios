#!/bin/bash
# Build the vendored libghostty-vt static library for iOS (aarch64) from
# Vendor/herdr/upstream/vendor/libghostty-vt without touching the Vendor tree.
#
# WHY THIS SHAPE (herdr 0.9.1+)
#   herdr 0.9.1's vendored libghostty-vt declares minimum_zig_version 0.16.0
#   (build.zig.zon, enforced by herdr's build.rs). zig 0.16.0 also fixed the
#   macOS 26 host-link bug (bundled lld could not read the macOS 26 SDK's
#   libSystem.tbd) that made ANY zig-driven executable link fail under
#   0.15.2 — which used to kill `zig build` itself plus the vendored table
#   generators and forced the previous hand-materialized `zig build-lib`
#   replay (see git history for that shape and
#   .sisyphus/evidence/herdr-embed-t2.log for the original proofs).
#
#   With a working host link, upstream's own build graph runs on-host:
#       zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dsimd=false \
#         -Dtarget=<t> -Demit-xcframework=false
#   which is exactly the configuration the herdr binary's build.rs requests
#   (minus the xcframework packaging). simd=off keeps the scalar fallbacks;
#   the C ABI surface is identical and no C++ SIMD deps are needed.
#
#   The build runs on a SCRATCH COPY of the vendored tree under
#   .build-artifacts/ (zig build writes zig-out/ and .zig-cache into the
#   source tree; Vendor/herdr/upstream stays pristine), with per-target
#   --prefix and repo-local zig caches.
#
#   zig 0.16.0's ar output links cleanly with Apple ld (the 0.15.x
#   unaligned-member defect that required the libtool repack is gone);
#   verify_artifact still audits every archive.
#
# Idempotent: re-running reuses the downloaded zig and the global dep cache.
# All outputs are repo-local.
#
# Usage:
#   scripts/herdr-vt-build.sh                 # build aarch64-ios (device)
#   HERDR_VT_TARGETS="aarch64-ios aarch64-ios-simulator" scripts/herdr-vt-build.sh
#   HERDR_VT_BUILD=0 scripts/herdr-vt-build.sh   # verify existing artifacts only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh

VT_SRC="Vendor/herdr/upstream/vendor/libghostty-vt"
OUT_ROOT="$ROOT/.build-artifacts/herdr-vt"
WORK="$OUT_ROOT/work"
ZIG_VERSION="0.16.0"
ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
ZIG_TARBALL="https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
ZIG_GLOBAL_CACHE="$ROOT/.build-artifacts/zig-cache/global"

TARGETS="${HERDR_VT_TARGETS:-aarch64-ios}"

log() { printf '[herdr-vt-build] %s\n' "$*"; }
die() { printf '[herdr-vt-build] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- zig 0.16.0
export ZIG_GLOBAL_CACHE_DIR="$ZIG_GLOBAL_CACHE"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

find_zig() {
  local cand
  for cand in \
    "$OUT_ROOT/zig-$ZIG_VERSION/zig" \
    ".build-artifacts/zig-dl/zig-aarch64-macos-$ZIG_VERSION/zig" \
    ".build-artifacts/tools/zig-aarch64-macos-$ZIG_VERSION/zig"; do
    if [[ -x "$cand" ]]; then
      [[ "$("$cand" version)" == "$ZIG_VERSION" ]] || continue
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

if ! ZIG_BIN="$(find_zig)"; then
  log "zig $ZIG_VERSION not found; downloading $ZIG_TARBALL"
  mkdir -p "$OUT_ROOT"
  curl -fL --retry 3 -o "$OUT_ROOT/zig.tar.xz" "$ZIG_TARBALL"
  echo "$ZIG_SHA256  $OUT_ROOT/zig.tar.xz" | shasum -a 256 -c - >/dev/null \
    || die "zig tarball sha256 mismatch"
  rm -rf "$OUT_ROOT/zig-$ZIG_VERSION"
  mkdir -p "$OUT_ROOT/zig-$ZIG_VERSION"
  tar -xJf "$OUT_ROOT/zig.tar.xz" -C "$OUT_ROOT/zig-$ZIG_VERSION" --strip-components=1
  rm -f "$OUT_ROOT/zig.tar.xz"
  ZIG_BIN="$(find_zig)" || die "zig download produced no usable binary"
fi
log "zig: $ZIG_BIN ($("$ZIG_BIN" version))"

test -d "$VT_SRC" || die "missing $VT_SRC (checkout the pinned herdr ref first)"

# ------------------------------------------------------------------ the .a
build_lib() {
  local target="$1"
  local outdir="$OUT_ROOT/$target"
  local lib="$outdir/libghostty-vt.a"
  local src_copy="$WORK/src-$target"
  mkdir -p "$outdir"
  rm -f "$lib"
  rm -rf "$src_copy"
  cp -R "$VT_SRC" "$src_copy"
  (cd "$src_copy" && "$ZIG_BIN" build \
    -Demit-lib-vt \
    -Doptimize=ReleaseFast \
    -Dsimd=false \
    -Dtarget="$target" \
    -Demit-xcframework=false \
    --prefix "$outdir/zig-out" \
    --cache-dir "$WORK/zig-local-cache-$target") || die "zig build failed for $target"
  local built="$outdir/zig-out/lib/libghostty-vt.a"
  [[ -f "$built" ]] || die "zig build produced no $built"
  cp "$built" "$lib"
  rm -rf "$outdir/zig-out" "$src_copy"
  log "built $lib ($(du -h "$lib" | cut -f1))"
}

verify_artifact() {
  local target="$1"
  local lib="$OUT_ROOT/$target/libghostty-vt.a"
  local evidence="$OUT_ROOT/$target/nm-exports.txt"
  file "$lib" | grep -q 'ar archive' || die "$lib is not an ar archive"
  lipo -info "$lib" | grep -q 'arm64' || die "$lib does not contain arm64"
  nm -gU "$lib" | awk '{ print $3 }' | grep '^_ghostty_' | sort > "$evidence" \
    || die "nm produced no ghostty_* exports for $lib"
  local count
  count="$(wc -l < "$evidence" | tr -d ' ')"
  log "$lib exports $count ghostty_* symbols (-> $evidence)"
}

if [[ "${HERDR_VT_BUILD:-1}" != "1" ]]; then
  log "HERDR_VT_BUILD=0: skipping build, verifying existing artifacts only"
  for t in $TARGETS; do verify_artifact "$t"; done
  exit 0
fi

mkdir -p "$WORK"
for t in $TARGETS; do
  build_lib "$t"
  verify_artifact "$t"
done
log "done: $OUT_ROOT/<target>/libghostty-vt.a"
