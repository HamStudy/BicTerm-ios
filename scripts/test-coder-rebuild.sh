#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
bash scripts/coder-acceptance-up.sh g12-rebuild --parameter multi_agent=false --parameter script_mode=normal --parameter start_blocks_login=true
ruby scripts/coder-acceptance-state.rb g12-rebuild --wait-connected
rm -f Fixtures/run/coder-acceptance/g12-rebuild/rebuild-request Fixtures/run/coder-acceptance/g12-rebuild/rebuild-ready
bash scripts/coder-rebuild-on-request.sh > .sisyphus/evidence/phase2-g12-b-rebuild-agent.log 2>&1 &
watcher=$!
cleanup() { if kill -0 "$watcher" 2>/dev/null; then kill "$watcher"; fi; }
trap cleanup EXIT
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    DERIVED_DATA="$ROOT/.build-artifacts/DerivedData/g12-core" \
    ONLY_TESTING='BicTermCoreTests/CoderNativeRebuildAcceptanceTests' \
    EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-b-rebuild-tests.log' \
    scripts/test-core.sh
wait "$watcher"
