#!/bin/bash
# coder-dev-down.sh — tear down the native Coder dev-server fixture:
# kills the server + host agent processes (matched by fixture path, not by
# generic binary name), verifies port 7080 is closed, and removes all fixture
# state under Fixtures/run/coder-dev/ and the credential env file.
# Idempotent; exits non-zero only if something survives.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/Fixtures/run"
DEV="$RUN/coder-dev"
BIN_DIR="$RUN/coder-bin"
ENV_FILE="$RUN/coder-dev.env"
PORT=7080

LOG="$ROOT/.sisyphus/evidence/phase2-g6-fixture-down.log"
mkdir -p "$ROOT/.sisyphus/evidence"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

kill_pidfile() { # kill_pidfile <pidfile>
  local pidfile="$1" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

# 1. Recorded pids: server + per-workspace agents.
kill_pidfile "$DEV/server.pid"
for f in "$DEV/agents/"*.pid; do
  [ -e "$f" ] || continue
  kill_pidfile "$f"
done

# 2. Belt-and-suspenders: any leftover process whose command line references
#    this fixture's paths (server, agents, terraform children of provisioner).
fixture_pids() {
  pgrep -f "$BIN_DIR/coder" 2>/dev/null || true
  pgrep -f "$DEV" 2>/dev/null || true
}
pids="$(fixture_pids | sort -u)"
if [ -n "$pids" ]; then
  printf '%s\n' "$pids" | xargs kill 2>/dev/null || true
fi

# 3. Wait for death, escalate to -9, then check the port.
sleep 1
pids="$(fixture_pids | sort -u)"
if [ -n "$pids" ]; then
  printf '%s\n' "$pids" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

# 4. Port 7080 must be closed (grace window), and no fixture-path process may
#    survive.
for i in $(seq 1 100); do
  PORT_PIDS="$(lsof -nP -ti ":$PORT" 2>/dev/null || true)"
  [ -z "$PORT_PIDS" ] && break
  sleep 0.1
done
SURVIVORS="$(fixture_pids | sort -u)"
PORT_PIDS="$(lsof -nP -ti ":$PORT" 2>/dev/null || true)"
if [ -n "$SURVIVORS" ] || [ -n "$PORT_PIDS" ]; then
  echo "coder-dev-down: FAIL — survivors:"
  [ -n "$SURVIVORS" ] && ps -o pid,command -p "$(printf '%s\n' "$SURVIVORS" | tr '\n' ',' | sed 's/,$//')" || true
  [ -n "$PORT_PIDS" ] && echo "port $PORT still held by: $PORT_PIDS"
  exit 1
fi

# 5. Remove all fixture state (config/postgres data, cache, agents, tmp,
#    template copy, server.log) and the credential env file. The downloaded
#    binary cache Fixtures/run/coder-bin/ is kept (re-verified on next up).
rm -rf "$DEV"
rm -f "$ENV_FILE"

echo "coder-dev-down: no fixture processes, port $PORT closed, Fixtures/run/coder-dev removed"
exit 0
