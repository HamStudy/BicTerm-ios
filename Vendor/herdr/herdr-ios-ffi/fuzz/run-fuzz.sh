#!/bin/bash
# Runs every herdr fuzz target for a bounded time budget and archives the
# evidence log. Usage: bash run-fuzz.sh [seconds-per-target]
# Requires the repository-local rust caches (see ../check.sh preamble) and
# a nightly toolchain (cargo-fuzz requirement).
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
source scripts/env-local-caches.sh
export RUSTUP_HOME="$root/.build-artifacts/rustup"
export PATH="$root/.build-artifacts/tools/bin:$PATH"
budget="${1:-600}"
evidence="$root/.sisyphus/evidence"
mkdir -p "$evidence"
# cargo-fuzz resolves the ./fuzz directory relative to the crate it runs in.
cd "$root/Vendor/herdr/herdr-ios-ffi"
for target in length_parse bincode_decode endpoint_json patch_apply; do
    echo "=== fuzz $target (${budget}s) ==="
    cargo +nightly fuzz run "$target" -- -runs=100000000 -max_total_time="$budget" \
        2>&1 | tee "$evidence/phase2-h20-fuzz-$target.log"
done
echo "all fuzz targets completed without untriaged crashes"
