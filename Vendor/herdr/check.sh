#!/bin/bash
set -euo pipefail
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
export PATH="$PWD/.build-artifacts/tools/bin:$PATH"
manifest=Vendor/herdr/Cargo.toml
evidence=.sisyphus/evidence
test -d "$evidence"
test "$(GIT_MASTER=1 git -C Vendor/herdr/upstream rev-parse HEAD)" = b99002ac99b09e00b4ca692436cb15a6b0d676f1
test -z "$(GIT_MASTER=1 git -C Vendor/herdr/upstream status --porcelain)"
cargo fmt --manifest-path "$manifest" --all -- --check
cargo test --locked --manifest-path "$manifest" -p herdr-protocol -p herdr-client-core -p herdr-ios-ffi 2>&1 | tee "$evidence/phase2-h13-tests.log"
for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
    cargo build --locked --manifest-path "$manifest" --target "$target" 2>&1 | tee "$evidence/phase2-h13-build-$target.log"
done
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    cargo tree --locked --manifest-path "$manifest" --target "$target" --edges normal,build --prefix none --format '{p}|{l}' > "$evidence/phase2-h13-licenses-$target.log"
    cargo metadata --locked --manifest-path "$manifest" --filter-platform "$target" --format-version 1 > "$evidence/phase2-h13-metadata-$target.json"
    cargo-deny --manifest-path "$manifest" --config Vendor/herdr/deny.toml --target "$target" --exclude-dev --locked list --format json --layout crate > "$evidence/phase2-h13-license-graph-$target.json"
    jq --arg target "$target" --slurpfile graph "$evidence/phase2-h13-license-graph-$target.json" '{target: $target, packages: [.packages[] | select([.name,.version] as $key | $graph[0] | keys | any(split(" ")[0:2] == $key)) | {name,version,license}] | sort_by(.name)}' "$evidence/phase2-h13-metadata-$target.json" > "$evidence/phase2-h13-inventory-$target.json"
done
jq -s '.' "$evidence/phase2-h13-inventory-aarch64-apple-ios.json" "$evidence/phase2-h13-inventory-aarch64-apple-ios-sim.json" > Vendor/herdr/LICENSE_INVENTORY.json
cargo-deny --manifest-path "$manifest" --config Vendor/herdr/deny.toml --exclude-dev --locked check 2>&1 | tee "$evidence/phase2-h13-cargo-deny.log"
for mode in unlicensed unknown; do
    jq --arg mode "$mode" '(.packages[] | select(.name == "herdr-client-core") | .license) = (if $mode == "unlicensed" then null else "LicenseRef-Unapproved" end)' "$evidence/phase2-h13-metadata-aarch64-apple-ios.json" > "$evidence/phase2-h13-$mode-metadata.json"
    if cargo-deny --manifest-path "$manifest" --config Vendor/herdr/deny.toml --metadata-path "$evidence/phase2-h13-$mode-metadata.json" --exclude-dev --locked check licenses > "$evidence/phase2-h13-$mode-rejection.log" 2>&1; then
        printf 'FAIL: license policy accepted %s metadata\n' "$mode"
        exit 1
    fi
    grep -qE 'error\[(unlicensed|rejected)\]' "$evidence/phase2-h13-$mode-rejection.log"
done
pattern='crate::(server|pty|ghostty|remote|ipc)::|use[[:space:]]+(portable_pty|ghostty|crossterm|ratatui|interprocess)::|std::process::Command|tokio::process'
if grep -RnE "$pattern" Vendor/herdr/herdr-protocol/src Vendor/herdr/herdr-client-core/src > "$evidence/phase2-h13-exclusion-audit.log"; then
    printf 'FAIL: excluded runtime import or process spawning found\n' >> "$evidence/phase2-h13-exclusion-audit.log"
    exit 1
else
    status=$?
    test "$status" -eq 1
    printf 'PASS: zero excluded runtime imports or process-spawning references in either crate source tree\n' >> "$evidence/phase2-h13-exclusion-audit.log"
fi
for file in Vendor/herdr/herdr-protocol/src/*.rs Vendor/herdr/herdr-ios-ffi/src/*.rs; do
    awk 'NF && $0 !~ /^[[:space:]]*\/\// {n++} END {if(n>250) {print FILENAME,n; exit 1}}' "$file"
done
printf 'PASS: host tests, three target builds, license/advisory/source/ban policy, and exclusion audit\n'
