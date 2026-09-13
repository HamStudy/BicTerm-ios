#!/bin/bash
# Build the vendored libghostty-vt static library for iOS (aarch64) from
# Vendor/herdr/upstream/vendor/libghostty-vt without touching the Vendor tree.
#
# WHY THIS SHAPE
#   herdr's build.rs normally runs `zig build -Demit-lib-vt -Dtarget=<t>` inside
#   vendor/libghostty-vt. On this macOS 26 host that is impossible: zig 0.15.2's
#   bundled `zig ld` cannot load the macOS 26.x SDK's libSystem.tbd, so ANY
#   zig-driven executable link fails (undefined _abort/_bzero/... HOST symbols).
#   That kills `zig build` (it must link its build runner) and the vendored
#   tree's three table generators (host executables). See
#   .sisyphus/evidence/phase2-h16-server-fixture.md and the addendum in
#   .sisyphus/evidence/herdr-support-embed-spike.log.
#
#   The spike proved static archives still build: `zig build-lib` never invokes
#   the broken host linker. This script therefore:
#     1. materializes every generated module the vt library expects, by
#        compiling the vendored table generators with `zig build-exe` and then
#        replaying zig's own --verbose-link line through Apple's `xcrun ld`
#        (which links the SDK fine) — no off-host step needed;
#     2. runs `zig build-lib` directly with an explicit module graph,
#        replicating GhosttyLibVt.initStatic() for -Demit-lib-vt:
#          zig build-lib \
#            -target aarch64-ios.17.0 -O ReleaseFast -fPIC -fllvm \
#            -fno-compiler-rt -fno-ubsan-rt \
#            --dep build_options --dep terminal_options \
#            --dep uucode --dep unicode_tables --dep symbols_tables \
#            -Mroot=src/lib_vt.zig ... \
#        GOTCHAS proven on zig 0.15.2 (do not "clean up"):
#          * -target MUST precede the --dep/-M args — after them it is
#            silently ignored and the build targets the macOS host.
#          * bundled -fcompiler-rt/-fubsan-rt land as macOS objects inside
#            an iOS archive; leave them off (rust's compiler-builtins and the
#            app toolchain provide the runtime symbols).
#        (upstream builds iOS at os_version_min 17; static lib config: PIC,
#        LLVM backend on Darwin, simd disabled so no C++ SIMD deps are needed
#        — the C ABI surface is identical).
#
# OFF-HOST FALLBACK (documented, not required on this host)
#   If any zig compile step fails on a future host, the identical .a can be
#   produced on any macOS <= 25 / Linux box with zig 0.15.2 by running, inside
#   a pristine copy of vendor/libghostty-vt:
#       zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dsimd=false \
#         -Dtarget=aarch64-ios -Demit-xcframework=false
#   and copying zig-out/lib/libghostty-vt.a over the vendored artifact checked
#   in at Vendor/herdr/embed/. Consumers that only need the artifact (the
#   normal case — the .a is committed) can pass HERDR_VT_BUILD=0 and skip this
#   script entirely.
#
# Idempotent: re-running reuses the downloaded zig, the fetched uucode dep, and
# any step whose output already exists. All outputs are repo-local.
#
# Usage:
#   scripts/herdr-vt-build.sh                 # build aarch64-ios (device)
#   HERDR_VT_TARGETS="aarch64-ios aarch64-ios-simulator" scripts/herdr-vt-build.sh
#   HERDR_VT_BUILD=0 scripts/herdr-vt-build.sh   # verify committed artifact only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh

VT_SRC="Vendor/herdr/upstream/vendor/libghostty-vt"
OUT_ROOT="$ROOT/.build-artifacts/herdr-vt"
WORK="$OUT_ROOT/work"
ZIG_VERSION="0.15.2"
ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
ZIG_TARBALL="https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
ZIG_GLOBAL_CACHE="$ROOT/.build-artifacts/zig-cache/global"
UUCODE_NAME="uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9"
UUCODE_URL="https://deps.files.ghostty.org/$UUCODE_NAME.tar.gz"

TARGETS="${HERDR_VT_TARGETS:-aarch64-ios}"

log() { printf '[herdr-vt-build] %s\n' "$*"; }
die() { printf '[herdr-vt-build] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- zig 0.15.2
export ZIG_GLOBAL_CACHE_DIR="$ZIG_GLOBAL_CACHE"
export ZIG_LOCAL_CACHE_DIR="$WORK/zig-local-cache"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

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

# ---------------------------------------------------------------- uucode dep
# The vt unicode machinery needs the uucode package (build.zig.zon dep) plus
# the tables its generator emits from the pinned UCD data inside the tarball.
UUCODE_DIR=""
for cand in "$ZIG_GLOBAL_CACHE_DIR/p/$UUCODE_NAME"; do
  if [[ -d "$cand" ]]; then UUCODE_DIR="$cand"; break; fi
done
if [[ -z "$UUCODE_DIR" ]]; then
  log "uucode dep not in cache; fetching $UUCODE_URL"
  "$ZIG_BIN" fetch "$UUCODE_URL" >/dev/null
  UUCODE_DIR="$ZIG_GLOBAL_CACHE_DIR/p/$UUCODE_NAME"
  [[ -d "$UUCODE_DIR" ]] || die "zig fetch did not populate $UUCODE_DIR"
fi
log "uucode: $UUCODE_DIR"

# ------------------------------------------------- host-exe link via xcrun ld
# zig 0.15.2 on macOS 26 fails its OWN executable links (SDK libSystem.tbd is
# unreadable for its bundled lld). Compilation is fine, so we let zig compile,
# take the exact `zig ld ...` line it prints with --verbose-link, and replay it
# through Apple's ld, which links the same objects against the same SDK
# successfully. Proven in .sisyphus/evidence/herdr-embed-t2.log.
# zig may leave a 0-byte stub at the -femit-bin path when its link fails, so
# judge success by Mach-O content, not existence.
is_macho_exe() {
  [[ -s "$1" ]] && file "$1" | grep -q 'Mach-O.*executable'
}

zig_build_host_exe() {
  local out="$1"; shift
  if is_macho_exe "$out"; then log "reuse host exe: $out"; return 0; fi
  rm -f "$out"
  local logtext linkline
  logtext="$("$ZIG_BIN" build-exe -femit-bin="$out" -fllvm \
              --verbose-link "$@" 2>&1 || true)"
  if is_macho_exe "$out"; then log "linked by zig directly: $out"; return 0; fi
  rm -f "$out"
  linkline="$(printf '%s\n' "$logtext" | grep -m1 '^zig ld ' || true)"
  if [[ -z "$linkline" ]]; then
    printf '%s\n' "$logtext" | tail -25 >&2
    die "no 'zig ld' line replayable for $*"
  fi
  # shellcheck disable=SC2086
  xcrun ld ${linkline#"zig ld "} >/dev/null
  is_macho_exe "$out" || die "xcrun ld replay produced no usable $out"
  log "linked via xcrun ld replay: $out"
}

# ------------------------------------------------------- generated modules
# The `zig build` graph generates: (a) uucode tables.zig, (b) ghostty
# props.zig/symbols.zig via two host generators, (c) build_options /
# terminal_options option modules. We materialize each by hand. The uucode
# package's module graph is circular at the named-module level (types -> get ->
# tables -> types), which the build-lib CLI cannot express, so the package is
# flattened into a single module copy whose named imports are rewritten to
# plain relative file imports. Only the work copy is edited; caches and Vendor
# stay pristine.
materialize_uucode_shim() {
  local shim="$WORK/uucode-src"
  [[ -f "$shim/tables.zig" ]] && { log "reuse uucode shim: $shim"; return 0; }
  rm -rf "$shim"
  mkdir -p "$shim"
  cp -R "$UUCODE_DIR/src/." "$shim/"
  # ghostty's build config becomes the build_config module root, flattened to
  # a sibling file so generated tables can reach it relatively.
  sed -e 's|@import("config.x.zig")|@import("x/config.x.zig")|g' \
      "$VT_SRC/src/build/uucode_config.zig" > "$shim/build_config.zig"
  # The generated tables anchor extension types through build_config.types_x;
  # the named-module wiring provides it, the flat copy must re-export it.
  printf '\npub const types_x = @import("x/types.x.zig");\n' >> "$shim/build_config.zig"
  # Named-module imports -> relative file imports inside the flattened package.
  sed -i '' 's|@import("tables")|@import("tables.zig")|g' "$shim/get.zig"
  sed -i '' 's|@import("get.zig")|@import("../get.zig")|g' "$shim/x/root.zig"
  sed -i '' 's|@import("config.zig")|@import("../config.zig")|g' "$shim/x/grapheme.zig"
  sed -i '' -e 's|@import("config.zig")|@import("../../config.zig")|g' \
             -e 's|@import("types.x.zig")|@import("../types.x.zig")|g' \
             "$shim/x/config_x/grapheme_break.zig" "$shim/x/config_x/wcwidth.zig"
  # x/grapheme.zig imports ../build/Ucd.zig; keep only that file, flattened.
  sed -i '' -e 's|@import("types.zig")|@import("../types.zig")|g' \
             -e 's|@import("config.zig")|@import("../config.zig")|g' \
             "$shim/build/Ucd.zig"
  rm -f "$shim/build/tables.zig" "$shim/build/test_build_config.zig"
  log "uucode shim prepared: $shim"
}

generate_tables() {
  local shim="$WORK/uucode-src"
  if [[ -f "$shim/tables.zig" ]] \
     && head -1 "$shim/tables.zig" | grep -q 'auto-generated'; then
    log "reuse tables.zig"; return 0
  fi
  # The flattened package pulls get.zig -> tables.zig during generator
  # compilation; a placeholder satisfies that until the real file exists.
  printf 'pub const tables = .{};\n' > "$shim/tables.zig"
  # Generator = uucode src/build/tables.zig, placed as a sibling of the
  # package files it imports (zig forbids imports outside the module root).
  # Host target, Debug: upstream notes ReleaseFast table generation is broken.
  sed -e 's|@import("build_config")|@import("build_config.zig")|g' \
      "$UUCODE_DIR/src/build/tables.zig" > "$shim/gen_tables_main.zig"
  cp "$UUCODE_DIR/src/build/Ucd.zig" "$shim/Ucd.zig"
  zig_build_host_exe "$shim/gen_tables_bin" "-Mroot=$shim/gen_tables_main.zig"
  # Ucd.zig opens the pinned ucd/ data files relative to the package root.
  (cd "$UUCODE_DIR" && "$shim/gen_tables_bin" "$shim/tables.zig")
  # Generated header uses named imports; redirect to the flattened neighbors.
  sed -i '' -e 's|@import("types.x.zig")|@import("x/types.x.zig")|g' \
             -e 's|@import("build_config")|@import("build_config.zig")|g' \
             "$shim/tables.zig"
  rm -f "$shim/gen_tables_bin" "$shim/gen_tables_main.zig" "$shim/Ucd.zig"
  log "generated tables.zig ($(wc -l < "$shim/tables.zig") lines)"
}

generate_ghostty_tables() {
  local shim="$WORK/uucode-src" gen="$WORK/gen-vt"
  if [[ -f "$gen/props.zig" && -f "$gen/symbols.zig" ]]; then
    log "reuse props.zig/symbols.zig"; return 0
  fi
  rm -rf "$gen"; mkdir -p "$gen"
  local name src
  for name in props symbols; do
    src="$VT_SRC/src/unicode/${name}_uucode.zig"
    zig_build_host_exe "$gen/${name}-unigen" \
      --dep uucode "-Mroot=$src" "-Muucode=$shim/root.zig"
    "$gen/${name}-unigen" > "$gen/${name}.zig"
    log "generated ${name}.zig ($(wc -l < "$gen/${name}.zig") lines)"
  done
}

# Option modules mirroring Config.addOptions()/terminal build_options.add()
# for the lib artifact (see src/build/GhosttyZig.zig initInner + Config.zig
# terminalOptions): c_abi on (vt_c module), oniguruma off (never allowed in
# the vt lib), simd off (no C++ SIMD deps; identical C ABI), ReleaseFast.
# Zig analyzes option files lazily, so only the fields the vt graph reads need
# to exist. Version comes from the vendored VERSION file.
write_option_modules() {
  local gen="$WORK/gen-vt"
  local version
  version="$(tr -d ' \n' < "$VT_SRC/VERSION")"
  # shellcheck disable=SC2016
  printf '%s\n' \
    'const std = @import("std");' \
    'pub const simd = false;' \
    'pub const sentry = false;' \
    'pub const flatpak = false;' \
    'pub const snap = false;' \
    'pub const x11 = false;' \
    'pub const wayland = false;' \
    'pub const i18n = true;' \
    "pub const app_version_string = \"$version\";" \
    "pub const lib_version_string = \"$version\";" \
    > "$gen/build_options.zig"
  # shellcheck disable=SC2016
  printf '%s\n' \
    'const std = @import("std");' \
    'pub const Artifact = enum { ghostty, lib };' \
    'pub const artifact: Artifact = .lib;' \
    'pub const c_abi = true;' \
    'pub const oniguruma = false;' \
    'pub const simd = false;' \
    'pub const slow_runtime_safety = false;' \
    'pub const kitty_graphics = true;' \
    'pub const tmux_control_mode = false;' \
    "pub const version_string = \"$version\";" \
    'pub const version_major: usize = 1;' \
    'pub const version_minor: usize = 3;' \
    'pub const version_patch: usize = 2;' \
    'pub const version_pre: ?[]const u8 = "-dev";' \
    'pub const version_build: ?[]const u8 = null;' \
    > "$gen/terminal_options.zig"
  log "option modules written (lib, c_abi, no-simd, $version)"
}

# ------------------------------------------------------------------ the .a
build_lib() {
  local target="$1"
  # os_version_min 17 like upstream Config.osVersionMin; the simulator ABI
  # slot cannot carry a version suffix (zig parses it as an ABI version).
  local zig_target="$target"
  [[ "$target" == *-simulator ]] || zig_target="$target.17.0"
  local outdir="$OUT_ROOT/$target"
  local lib="$outdir/libghostty-vt.a"
  mkdir -p "$outdir"
  rm -f "$lib"
  # shellcheck disable=SC2086
  "$ZIG_BIN" build-lib \
    -target "$zig_target" \
    -O ReleaseFast \
    -fPIC -fllvm -fno-compiler-rt -fno-ubsan-rt \
    --dep build_options --dep terminal_options \
    --dep uucode --dep unicode_tables --dep symbols_tables \
    "-Mroot=$VT_SRC/src/lib_vt.zig" \
    "-Mbuild_options=$WORK/gen-vt/build_options.zig" \
    "-Mterminal_options=$WORK/gen-vt/terminal_options.zig" \
    "-Muucode=$WORK/uucode-src/root.zig" \
    "-Municode_tables=$WORK/gen-vt/props.zig" \
    "-Msymbols_tables=$WORK/gen-vt/symbols.zig" \
    --name ghostty-vt \
    -femit-bin="$lib"
  [[ -f "$lib" ]] || die "zig build-lib produced no $lib"
  # zig's ar writes unaligned members (Apple ld rejects them: "member not
  # 8-byte aligned") and zeroed file modes; repack with Apple libtool so any
  # Mach-O linker (Apple ld, rust-lld) can consume the archive.
  local repack="$outdir/repack"
  rm -rf "$repack"; mkdir -p "$repack"
  (cd "$repack" && ar x "$lib" && chmod 644 ./*.o)
  xcrun libtool -static -o "$lib" "$repack"/*.o
  rm -rf "$repack"
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

materialize_uucode_shim
generate_tables
generate_ghostty_tables
write_option_modules
for t in $TARGETS; do
  build_lib "$t"
  verify_artifact "$t"
done
log "done: $OUT_ROOT/<target>/libghostty-vt.a"
