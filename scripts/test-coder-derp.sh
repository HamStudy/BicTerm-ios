#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
DEV="$ROOT/Fixtures/run/coder-dev"
EVIDENCE="$ROOT/.sisyphus/evidence"
BUILD="$ROOT/.build-artifacts/coder-g12-host"
mkdir -p "$BUILD"
go build -o "$BUILD/derp-proxy" Fixtures/coder/derp-proxy.go
proxy_pid=""

stop_server() {
    local pid
    read -r pid < "$DEV/server.pid"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        for attempt in {1..100}; do
            if ! kill -0 "$pid" 2>/dev/null; then return; fi
            sleep 0.2
        done
        return 1
    fi
}

stop_proxy() {
    if [ -n "$proxy_pid" ]; then
        if kill -0 "$proxy_pid" 2>/dev/null; then kill "$proxy_pid"; fi
        if wait "$proxy_pid"; then
            :
        else
            local status=$?
            if [ "$status" -ne 143 ]; then return "$status"; fi
        fi
        proxy_pid=""
    fi
}

restore() {
    local status=$?
    trap - EXIT
    stop_proxy
    stop_server
    bash scripts/coder-dev-up.sh > "$EVIDENCE/phase2-g12-final-derp-restore.log" 2>&1
    exit "$status"
}
trap restore EXIT

for mode in fallback forced; do
    stop_server
    stop_proxy
    reject=0
    force=false
    if [ "$mode" = fallback ]; then reject=1; else force=true; fi
    CODER_GATE_REJECT_DERP="$reject" "$BUILD/derp-proxy" \
        </dev/null > "$EVIDENCE/phase2-g12-final-derp-$mode-proxy.log" 2>&1 &
    proxy_pid=$!
    env CODER_CONFIG_DIR="$DEV/config" CODER_CACHE_DIRECTORY="$DEV/cache" \
        TMPDIR="$DEV/tmp" CODER_BLOCK_DIRECT=true CODER_DERP_FORCE_WEBSOCKETS="$force" \
        Fixtures/run/coder-bin/coder server --http-address 127.0.0.1:7080 \
        --access-url http://127.0.0.1:7081 --update-check=false \
        --derp-server-stun-addresses disable --stats-collection-usage-stats-enable=false \
        </dev/null >> "$DEV/server.log" 2>&1 &
    printf '%s\n' "$!" > "$DEV/server.pid"
    bash scripts/coder-dev-up.sh > "$EVIDENCE/phase2-g12-final-derp-$mode-fixture.log" 2>&1
    CODER_GATE_URL=http://127.0.0.1:7081 CODER_GATE_EXPECT_PATH=relayed bash scripts/test-coder-raw.sh \
        > "$EVIDENCE/phase2-g12-final-derp-$mode-raw.log" 2>&1
    grep 'upgrade=websocket status=101' "$EVIDENCE/phase2-g12-final-derp-$mode-proxy.log"
    if [ "$mode" = fallback ]; then
        grep 'upgrade=derp status=403' "$EVIDENCE/phase2-g12-final-derp-$mode-proxy.log"
        printf 'PASS A16 custom-upgrade rejection followed by WebSocket relay\n'
    else
        if grep -q 'upgrade=derp' "$EVIDENCE/phase2-g12-final-derp-$mode-proxy.log"; then exit 1; fi
        printf 'PASS A17 forced WebSocket relay, no initial custom DERP upgrade\n'
    fi
done
