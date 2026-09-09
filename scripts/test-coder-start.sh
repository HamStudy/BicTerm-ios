#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
export CODER_CONFIG_DIR="$ROOT/Fixtures/run/coder-dev/config" CODER_CACHE_DIRECTORY="$ROOT/Fixtures/run/coder-dev/cache"
export CODER_USE_KEYRING=false
set -a
source Fixtures/run/coder-dev.env
set +a
for name in g12-start-explicit g12-start-lost; do
    bash scripts/coder-acceptance-up.sh "$name" --parameter multi_agent=false --parameter script_mode=normal --parameter start_blocks_login=true
    ruby scripts/coder-acceptance-state.rb "$name" --wait-connected > "Fixtures/run/coder-acceptance/$name/before-stop.json"
    Fixtures/run/coder-bin/coder stop "$name" --yes
    read -r pid < "Fixtures/run/coder-acceptance/$name/main.pid"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
    rm -f "Fixtures/run/coder-acceptance/$name/main.pid"
done
ruby scripts/coder-acceptance-watch.rb g12-start-explicit g12-start-lost \
    > .sisyphus/evidence/phase2-g12-b-start-agent-ledger.log 2>&1 &
watcher=$!
cleanup() {
    kill "$watcher"
    wait "$watcher"
}
trap cleanup EXIT
for attempt in {1..100}; do
    if grep -q WATCHER_READY .sisyphus/evidence/phase2-g12-b-start-agent-ledger.log; then break; fi
    sleep 0.1
done
grep -q WATCHER_READY .sisyphus/evidence/phase2-g12-b-start-agent-ledger.log
xcodegen generate
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    -derivedDataPath "$ROOT/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO \
    -only-testing:BicTermTests/CoderNativeStartAcceptanceTests
