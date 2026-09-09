#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
for variant in blocking nonblocking error timeout; do
    name="g12-startup-$variant"
    base="Fixtures/run/coder-acceptance/$name"
    if [ -d "$base" ]; then rm -f "$base/release-startup" "$base/startup-entered" "$base/startup-completed"; fi
    mode=hold
    block=true
    case "$variant" in
        nonblocking) block=false ;;
        error|timeout) mode="$variant" ;;
    esac
    bash scripts/coder-acceptance-up.sh "$name" --parameter multi_agent=false --parameter "script_mode=$mode" --parameter "start_blocks_login=$block"
    ruby scripts/coder-acceptance-state.rb "$name" --wait-connected > ".sisyphus/evidence/phase2-g12-b-startup-$variant-state.log"
    for attempt in {1..100}; do
        if [ -f "$base/startup-entered" ]; then break; fi
        sleep 0.1
    done
    test -f "$base/startup-entered"
done
if [ "${CODER_STARTUP_PREPARE_ONLY:-0}" = 1 ]; then
    printf 'Startup fixtures prepared; no tests run in prepare-only mode\n'
    exit 0
fi
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    DERIVED_DATA="$ROOT/.build-artifacts/DerivedData/g12-core" \
    ONLY_TESTING='BicTermCoreTests/CoderNativeStartupAcceptanceTests' \
    EVIDENCE_LOG="${EVIDENCE_LOG:-.sisyphus/evidence/phase2-g12-b-startup-tests.log}" \
    scripts/test-core.sh
