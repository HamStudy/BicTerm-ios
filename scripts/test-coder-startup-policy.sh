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
for variant in blocking nonblocking; do
    name="g12-auto-$variant"
    base="Fixtures/run/coder-acceptance/$name"
    block=true
    if [ "$variant" = nonblocking ]; then block=false; fi
    if [ -d "$base" ]; then rm -f "$base/release-startup" "$base/startup-entered" "$base/startup-completed"; fi
    bash scripts/coder-acceptance-up.sh "$name" --parameter multi_agent=false --parameter script_mode=hold --parameter "start_blocks_login=$block"
    ruby scripts/coder-acceptance-state.rb "$name" --wait-connected > "$base/before-stop.json"
    Fixtures/run/coder-bin/coder stop "$name" --yes
    read -r pid < "$base/main.pid"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
    rm -f "$base/main.pid" "$base/release-startup" "$base/startup-entered" "$base/startup-completed"
done
ruby scripts/coder-acceptance-watch.rb g12-auto-blocking g12-auto-nonblocking \
    > .sisyphus/evidence/phase2-g12-b-auto-agent-ledger.log 2>&1 &
watcher=$!
cleanup() { kill "$watcher"; wait "$watcher"; }
trap cleanup EXIT
for attempt in {1..100}; do
    if grep -q WATCHER_READY .sisyphus/evidence/phase2-g12-b-auto-agent-ledger.log; then break; fi
    sleep 0.1
done
grep -q WATCHER_READY .sisyphus/evidence/phase2-g12-b-auto-agent-ledger.log
xcodegen generate
xcodebuild test -scheme BicTerm -destination 'platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    -derivedDataPath "$ROOT/.build-artifacts/DerivedData/g12-app" -parallel-testing-enabled NO \
    -only-testing:BicTermTests/CoderNativeStartupPolicyTests
