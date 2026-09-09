#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
mode="${1:-reset}"
case "$mode" in reset|resume) ;; *) exit 2 ;; esac
bash scripts/coder-acceptance-up.sh g12-control --parameter multi_agent=false --parameter script_mode=normal --parameter start_blocks_login=true
ruby scripts/coder-acceptance-state.rb g12-control --wait-connected
rm -f Fixtures/run/coder-acceptance/g12-control/proxy.json Fixtures/run/coder-acceptance/g12-control/reset-request
ruby scripts/coder-control-proxy.rb "$mode" > ".sisyphus/evidence/phase2-g12-b-control-$mode-proxy.log" 2>&1 &
proxy=$!
cleanup() { if kill -0 "$proxy" 2>/dev/null; then kill "$proxy"; fi; wait "$proxy"; }
trap cleanup EXIT
for attempt in {1..100}; do
    if [ -f Fixtures/run/coder-acceptance/g12-control/proxy.json ]; then break; fi
    sleep 0.1
done
test -f Fixtures/run/coder-acceptance/g12-control/proxy.json
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    DERIVED_DATA="$ROOT/.build-artifacts/DerivedData/g12-core" \
    ONLY_TESTING='BicTermCoreTests/CoderNativeControlRecoveryTests' \
    EVIDENCE_LOG=".sisyphus/evidence/phase2-g12-b-control-$mode-tests.log" \
    scripts/test-core.sh
