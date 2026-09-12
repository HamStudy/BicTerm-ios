#!/bin/bash
# BicTerm fixtures: tear down hop-1/hop-2 sshd + UDS forwarder. Idempotent.
# Verifies ports 12222/12223 are closed. Always exits 0 on success.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/Fixtures/run"

kill_pidfile() { # kill_pidfile <pidfile> <name>
  local pidfile="$1" name="$2"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
  fi
}

kill_pidfile "$RUN/hop1.pid" hop1
kill_pidfile "$RUN/hop2.pid" hop2
kill_pidfile "$RUN/uds_forward.pid" uds-forwarder

# lossy proxies (T12): one pidfile/control per listen port.
for lpid in "$RUN"/lossy-proxy-*.pid; do
  [ -f "$lpid" ] || continue
  kill_pidfile "$lpid" "$(basename "$lpid" .pid)"
done
rm -f "$RUN"/lossy-proxy-*.ctl
rm -f "$RUN/sshd-uds.sock"

# herdr fixture servers (one pidfile per fixture port; never pkill herdr —
# a real user herdr must be untouched).
for spid in "$RUN"/herdr/server-*/server.pid; do
  [ -f "$spid" ] || continue
  kill_pidfile "$spid" "$(basename "$(dirname "$spid")")"
done
rm -f "$RUN"/herdr/server-*/herdr.sock "$RUN"/herdr/server-*/herdr-client.sock

# Belt-and-suspenders: kill anything still bound to fixture ports.
for port in 12222 12223; do
  pids=$(lsof -nP -ti ":$port" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "$pids" | xargs kill 2>/dev/null || true
  fi
done

# Wait for ports to close (up to 10s).
for i in $(seq 1 100); do
  if ! lsof -nP -i :12222 -i :12223 2>/dev/null | grep -q LISTEN; then
    rm -f "$RUN/pids"
    echo "fixtures-down: all fixture ports closed"
    exit 0
  fi
  sleep 0.1
done

echo "fixtures-down: WARNING ports still open:"
lsof -nP -i :12222 -i :12223 2>/dev/null || true
exit 1
