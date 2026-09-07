#!/bin/bash
set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SPIKE_ROOT/../.." && pwd)"
SCRATCH="$REPO_ROOT/.scratch/task-20"
ARTIFACTS="$REPO_ROOT/.build-artifacts/task-20"
EVIDENCE="$REPO_ROOT/.sisyphus/evidence/task-20-coordinate.log"
PENDING_EVIDENCE="$SCRATCH/task-20-coordinate.pending.log"
FIXTURE_LOG="$SCRATCH/tailnet-fixture.log"
PORT=18082

mkdir -p "$SPIKE_ROOT/.build" "$SCRATCH/home" "$SCRATCH/tmp" \
    "$ARTIFACTS/clang-module-cache" "$ARTIFACTS/swiftpm-cache" \
    "$REPO_ROOT/.sisyphus/evidence"

export HOME="$SCRATCH/home"
export CFFIXED_USER_HOME="$SCRATCH/home"
export TMPDIR="$SCRATCH/tmp"
export CLANG_MODULE_CACHE_PATH="$ARTIFACTS/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ARTIFACTS/clang-module-cache"
export SWIFTPM_CACHE_PATH="$ARTIFACTS/swiftpm-cache"
export TAILNET_SPIKE_BASE_URL="http://127.0.0.1:$PORT"

FIXTURE_PID=""
PUBLISHED=0
exec 3>&1
cleanup() {
    if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
}
on_exit() {
    local rc=$?
    cleanup
    if [[ "$PUBLISHED" -eq 0 && -f "$PENDING_EVIDENCE" ]]; then
        cat "$PENDING_EVIDENCE" >&3
    fi
    return "$rc"
}
trap on_exit EXIT

run_and_record() {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    set +e
    "$@"
    local status=$?
    set -e
    printf 'exit_code=%d\n' "$status"
    return "$status"
}

require_fixture_line() {
    if ! grep -Fq "$1" "$FIXTURE_LOG"; then
        printf 'FAILED: expected fixture evidence not found: %s\n' "$1"
        return 1
    fi
    printf 'PASS fixture evidence: %s\n' "$1"
}

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    printf 'FAILED: loopback port %d is already in use\n' "$PORT" >&2
    exit 1
fi

: > "$PENDING_EVIDENCE"
exec > "$PENDING_EVIDENCE" 2>&1

printf 'Task 20 coordinate feasibility spike\n'
printf 'containment: HOME=%s TMPDIR=%s scratch=%s artifacts=%s\n' "$HOME" "$TMPDIR" "$SPIKE_ROOT/.build" "$ARTIFACTS"
run_and_record swift build \
    --package-path "$SPIKE_ROOT" \
    --scratch-path "$SPIKE_ROOT/.build"

"$SPIKE_ROOT/.build/debug/tailnet-fixture" \
    --port "$PORT" \
    --fixture "$SPIKE_ROOT/Fixtures/agent-connection.json" \
    --log "$FIXTURE_LOG" \
    --allowed-root "$REPO_ROOT" \
    > "$SCRATCH/tailnet-fixture.stdout.log" 2>&1 &
FIXTURE_PID=$!
printf 'fixture_pid=%d fixture_log=%s\n' "$FIXTURE_PID" "$FIXTURE_LOG"

for _ in $(seq 1 50); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
    sleep 0.1
done
if ! kill -0 "$FIXTURE_PID" 2>/dev/null || ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    printf 'FAILED: deterministic fixture did not become ready\n'
    exit 1
fi

run_and_record swift test \
    --package-path "$SPIKE_ROOT" \
    --scratch-path "$SPIKE_ROOT/.build"
run_and_record "$SPIKE_ROOT/.build/debug/tailnet-spike" \
    --base-url "$TAILNET_SPIKE_BASE_URL" \
    --token fixture-token

printf '%s\n' '--- deterministic fixture transcript ---'
cat "$FIXTURE_LOG"
printf '%s\n' '--- required evidence checks ---'
require_fixture_line "REST connection auth=valid status=200 derp_regions=2"
require_fixture_line "COORDINATE auth=valid status=101 version=2.0 token_header=present subprotocol=absent extensions=absent binary_bytes=25"
require_fixture_line "COORDINATE auth=missing status=401"
require_fixture_line "COORDINATE auth=invalid status=401"

cleanup
FIXTURE_PID=""
for _ in $(seq 1 20); do
    if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
    sleep 0.1
done
if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    printf 'FAILED: fixture port %d remained open after teardown\n' "$PORT"
    exit 1
fi

printf 'PASS fixture teardown: port %d closed\n' "$PORT"
printf 'TASK 20 COORDINATE RESULT: PASS\n'
mv "$PENDING_EVIDENCE" "$EVIDENCE"
PUBLISHED=1
cat "$EVIDENCE" >&3
