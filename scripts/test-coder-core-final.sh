#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
device="${1:?expected iphone or ipad}"
case "$device" in
    iphone) simulator=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E ;;
    ipad) simulator=3686DD9C-ACA2-4A79-8968-A9C3572C8276 ;;
    *) exit 2 ;;
esac
CODER_STARTUP_PREPARE_ONLY=1 bash scripts/test-coder-startup.sh
for name in g12-rebuild g12-control; do
    bash scripts/coder-acceptance-up.sh "$name" --parameter multi_agent=false --parameter script_mode=normal --parameter start_blocks_login=true
    ruby scripts/coder-acceptance-state.rb "$name" --wait-connected
done
rm -f Fixtures/run/coder-acceptance/g12-rebuild/rebuild-request Fixtures/run/coder-acceptance/g12-rebuild/rebuild-ready
rm -f Fixtures/run/coder-acceptance/g12-control/proxy.json Fixtures/run/coder-acceptance/g12-control/reset-request
bash scripts/coder-rebuild-on-request.sh > ".sisyphus/evidence/phase2-g12-final-$device-rebuild.log" 2>&1 &
watcher=$!
ruby scripts/coder-control-proxy.rb resume > ".sisyphus/evidence/phase2-g12-final-$device-control.log" 2>&1 &
proxy=$!
cleanup() {
    if kill -0 "$proxy" 2>/dev/null; then kill "$proxy"; fi
    if kill -0 "$watcher" 2>/dev/null; then kill "$watcher"; fi
    wait "$proxy" || true
    wait "$watcher" || true
}
trap cleanup EXIT
for attempt in {1..100}; do
    if [ -f Fixtures/run/coder-acceptance/g12-control/proxy.json ]; then break; fi
    sleep 0.1
done
test -f Fixtures/run/coder-acceptance/g12-control/proxy.json
DEST_OVERRIDE="platform=iOS Simulator,id=$simulator" \
    DERIVED_DATA="$ROOT/.build-artifacts/DerivedData/g12-core" \
    ONLY_TESTING='' EVIDENCE_LOG=".sisyphus/evidence/phase2-g12-final-core-$device.log" \
    scripts/test-core.sh
