#!/bin/bash
# herdr-embed-update.sh — HERDR-UPDATE runbook (user directive, plan
# herdr-embed T4): bump the pinned herdr ref and replay the embed patch
# series onto the new pristine tree, with mechanical proofs.
#
# Contract (see Vendor/herdr/EMBED-PATCHES.md "Updating the pinned herdr
# ref"):
#   * Failures surface as PATCH REJECTS at the patch layer (git apply
#     --3way conflicts) — semantic drift deeper than the patches is a
#     patch bug too: fix the .patch files, not the tree.
#   * The generated HerdrEmbed.h ABI is the ONLY Swift↔herdr contract.
#     Swift code must never depend on herdr internals — verified below.
#   * No proof step writes outside the repository.
#
# Usage:
#   HERDR_NEW_REF=<sha|tag|branch> scripts/herdr-embed-update.sh
#
# Optional env:
#   HERDR_UPDATE_DIR   working tree for the replay (default
#                      .build-artifacts/herdr-embed-update; wiped each run)
#   HERDR_SKIP_PROOFS  set 1 to stop after the patch replay + contract check
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env-local-caches.sh"
export RUSTUP_HOME="$ROOT/.build-artifacts/rustup"
export PATH="$ROOT/.build-artifacts/tools/bin:$PATH"

UPSTREAM="$ROOT/Vendor/herdr/upstream"
PATCHES="$ROOT/Vendor/herdr/embed-patches"
OUT="${HERDR_UPDATE_DIR:-$ROOT/.build-artifacts/herdr-embed-update}"
VT_DEVICE="$ROOT/Vendor/herdr/embed/libghostty-vt/aarch64-ios/libghostty-vt.a"
VT_MACOS="$ROOT/.build-artifacts/herdr-vt/aarch64-macos/libghostty-vt.a"
EMBED_CRATE="$ROOT/Vendor/herdr/herdr-ios-embed"

NEW_REF="${HERDR_NEW_REF:-}"
[ -n "$NEW_REF" ] || { echo "usage: HERDR_NEW_REF=<sha|tag|branch> $0" >&2; exit 1; }
test -d "$UPSTREAM/.git" || { echo "missing $UPSTREAM checkout" >&2; exit 1; }
test -d "$PATCHES" || { echo "missing $PATCHES" >&2; exit 1; }
test -f "$VT_DEVICE" || { echo "missing device libghostty-vt.a" >&2; exit 1; }

echo "== fetching $NEW_REF"
git -C "$UPSTREAM" fetch origin --tags
NEW_SHA="$(git -C "$UPSTREAM" rev-parse "$NEW_REF^{commit}")"
echo "new pin: $NEW_SHA"

echo "== extracting pristine tree"
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$UPSTREAM" archive "$NEW_SHA" | tar -x -C "$OUT"
# Own repo at its root, or `git apply` silently skips toplevel-relative
# patches inside an enclosing repo (same trap as herdr-embed-prepare.sh).
git -C "$OUT" init -q
git -C "$OUT" config user.name "herdr-embed-update"
git -C "$OUT" config user.email "embed@bicterm.invalid"
git -C "$OUT" add -A
git -C "$OUT" commit -qm "base: herdr $NEW_SHA"

echo "== replaying patch series (git apply --3way)"
shopt -s nullglob
patch_files=("$PATCHES"/[0-9]*.patch)
shopt -u nullglob
apply_failed=0
for patch in "${patch_files[@]}"; do
    echo "-- $(basename "$patch")"
    if ! git -C "$OUT" apply --3way "$patch"; then
        apply_failed=1
        echo "REJECT: $(basename "$patch")" >&2
    fi
done
if [ "$apply_failed" = "1" ]; then
    echo >&2
    echo "PATCH-LAYER REJECTS — fix the .patch files under Vendor/herdr/embed-patches/" >&2
    echo "(edit the patch, or regenerate it from $OUT's conflicted state), then re-run." >&2
    echo "Tree left at $OUT for manual resolution." >&2
    exit 1
fi
git -C "$OUT" diff --stat | tail -1

echo "== contract check: HerdrEmbed.h is the only Swift<->herdr boundary"
# Raw embed ABI symbols may appear ONLY in the app's Embed/ wrapper, its
# tests, and the clang-module header itself.
violations="$(grep -rn "herdr_embed_" \
    --include='*.swift' \
    "$ROOT/BicTerm" "$ROOT/BicTermTests" "$ROOT/BicTermUITests" "$ROOT/HerdrClientCore" \
    | grep -v "BicTerm/Herdr/Embed/" | grep -v "BicTermTests/Herdr/" || true)"
if [ -n "$violations" ]; then
    echo "CONTRACT VIOLATION: herdr_embed_* reached past the Embed wrapper:" >&2
    echo "$violations" >&2
    exit 1
fi
# No Swift file may include or import any herdr header/module other than
# the generated ABI module hosts.
include_violations="$(grep -rn "import Herdr\|#include.*[Hh]erdr" \
    --include='*.swift' "$ROOT/BicTerm" "$ROOT/BicTermTests" \
    | grep -v "import HerdrEmbed$" | grep -v "import HerdrClientCore$" || true)"
if [ -n "$include_violations" ]; then
    echo "CONTRACT VIOLATION: Swift reaches a herdr header past the module hosts:" >&2
    echo "$include_violations" >&2
    exit 1
fi
echo "contract check clean"

if [ "${HERDR_SKIP_PROOFS:-0}" = "1" ]; then
    echo "REPLAYED: $OUT (proofs skipped)"
    exit 0
fi

echo "== mechanical proofs"
export HERDR_LIBGHOSTTY_VT_PREBUILT=1
VT_DIR="$OUT/vendor/libghostty-vt/zig-out/lib"
mkdir -p "$VT_DIR"
cp "$VT_DEVICE" "$VT_DIR/libghostty-vt.a"

cargo clean --manifest-path "$OUT/Cargo.toml" -p herdr
cargo build --locked --manifest-path "$OUT/Cargo.toml" --target aarch64-apple-ios
cargo build --locked --manifest-path "$OUT/Cargo.toml" \
    --features bicterm-transport --target aarch64-apple-ios
echo "herdr binary proofs ok"

echo "== embed FFI proofs + T3 behavioral harness (against the replay tree)"
# The FFI crate path-depends on the DEFAULT working copy
# (.build-artifacts/herdr-embed); swap it aside and point the path at the
# replay tree so every proof below exercises the NEW sources. Restored by
# the trap even on proof failure.
DEFAULT_WORK="$ROOT/.build-artifacts/herdr-embed"
HAD_DEFAULT=0
if [ -d "$DEFAULT_WORK" ] && [ ! -L "$DEFAULT_WORK" ]; then
    HAD_DEFAULT=1
    mv "$DEFAULT_WORK" "$DEFAULT_WORK.update-bak"
fi
restore_default_workdir() {
    rm -f "$DEFAULT_WORK"
    if [ "$HAD_DEFAULT" = "1" ]; then
        mv "$DEFAULT_WORK.update-bak" "$DEFAULT_WORK"
    fi
}
trap restore_default_workdir EXIT
ln -s "$OUT" "$DEFAULT_WORK"

(
    cd "$EMBED_CRATE"
    cargo build --locked --target aarch64-apple-ios
    cargo build --locked --features bicterm-transport --target aarch64-apple-ios
)
echo "embed FFI build proofs ok"

if [ ! -f "$VT_MACOS" ]; then
    echo "(host libghostty-vt.a missing — building it for the harness)"
    HERDR_VT_TARGETS=aarch64-macos scripts/herdr-vt-build.sh
fi
(
    cd "$EMBED_CRATE"
    export HERDR_LIBGHOSTTY_VT_PREBUILT="$VT_MACOS"
    cargo test --test lifecycle
    cargo test --test headless_frame --test headless_detach --test headless_resize
)
echo "T3 harness ok"

restore_default_workdir
trap - EXIT

echo "== cbindgen drift check (report-only)"
mkdir -p "$ROOT/.scratch/tmp"
"$ROOT/.build-artifacts/tools/bin/cbindgen" "$EMBED_CRATE" --crate herdr-ios-embed \
    --config "$EMBED_CRATE/cbindgen.toml" -o "$ROOT/.scratch/tmp/HerdrEmbed.h"
if ! cmp -s "$ROOT/.scratch/tmp/HerdrEmbed.h" "$EMBED_CRATE/include/HerdrEmbed.h"; then
    echo "NOTE: HerdrEmbed.h drifted — regenerate via scripts/herdr-embed-prepare.sh" >&2
    echo "      and commit the header + HerdrEmbedC copy together." >&2
fi
rm -f "$ROOT/.scratch/tmp/HerdrEmbed.h"

cat <<EOF

REPLAY + PROOFS OK at $OUT (pin $NEW_SHA).

Promotion checklist (human steps, in order):
  1. Only needed when you resolved rejects manually in $OUT: re-split
     \`git -C $OUT diff\` back into the per-patch files under
     Vendor/herdr/embed-patches/ (same numbering, one logical change each).
  2. Bump the pins: BASE= in scripts/herdr-embed-prepare.sh,
     Vendor/herdr/MODIFICATIONS.md, and regenerate the provenance tar:
         git -C Vendor/herdr/upstream archive $NEW_SHA > Vendor/herdr/UPSTREAM_SOURCE.tar
         shasum -a 256 ... > Vendor/herdr/UPSTREAM_SOURCE.sha256 (same format)
  3. Re-materialize the default working copy + xcframework:
         scripts/herdr-embed-prepare.sh && scripts/herdr-embed-core.sh
  4. Rebuild the app (xcodegen generate if project.yml changed).
EOF
