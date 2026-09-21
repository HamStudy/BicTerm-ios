#!/bin/bash
# test-herdr-missing-server.sh — dedicated evidence run for
# BicTermUITests/HerdrConnectUITests.testMissingHerdrServerReachesTypedEmbedState.
#
# That test needs a fixture topology the standard suites never have: herdr
# server on 12222 ONLY (12223 = plain sshd, no herdr server), so the embed
# run meets a missing server and must terminate in a typed state. The
# standard fixtures-up topology starts herdr on BOTH ports, so in-suite the
# test skips by design; this wrapper flips the topology, runs JUST that
# test, and restores the standard topology afterwards.
#
# The state is VERIFIED (not assumed) before and after the test: the
# fixture sockets have several writers (fixtures-up, the app-hosted
# hardening tests' server reseed, the fixture bridge's auto-start), and a
# silently-wrong topology would make the test skip instead of fail — so
# the wrapper reconciles 12223 (stop any owner, pidfile or a
# bridge-auto-started stray, then clear the socket files) and retries
# until the gate state holds, failing loudly if it cannot.
#
# The restore reconciles 12223 first for the same reason: the test's
# bridge AUTO-STARTS a replacement server on the missing socket, and that
# server owns no pidfile, so fixtures-up alone would neither stop it nor
# clean its socket files (the same reconciliation
# HerdrEmbedHardeningTests.reseedFixtureServerForNextTest performs).
#
# Env overrides (same contract as test-core.sh / test-ui.sh):
#   DEST_OVERRIDE   Replaces the full -destination string.
#   DERIVED_DATA    Adds -derivedDataPath (default: repo-local, see below).
#   EVIDENCE_LOG    Replaces the tee'd log path (relative anchors to ROOT).
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=env-local-caches.sh
source "$ROOT/scripts/env-local-caches.sh"

RUN="$ROOT/Fixtures/run"
HERDR_BIN="$RUN/herdr/herdr"
DEST="${DEST_OVERRIDE:-platform=iOS Simulator,name=iPhone 17 Pro}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build-artifacts/DerivedData/herdr-missing-server}"
if [[ -n "${EVIDENCE_LOG:-}" ]]; then
    case "$EVIDENCE_LOG" in
        /*) LOG="$EVIDENCE_LOG" ;;
        *)  LOG="$ROOT/$EVIDENCE_LOG" ;;
    esac
else
    LOG="$ROOT/.sisyphus/evidence/herdr-missing-server-ui.log"
fi
mkdir -p "$(dirname "$LOG")" "$ROOT/.sisyphus/evidence"

if [ ! -x "$HERDR_BIN" ]; then
  echo "FAIL: herdr fixture binary absent ($HERDR_BIN) — run scripts/herdr-server-fetch.sh first"
  exit 1
fi

# connect(2) probe against a Unix domain socket: true when something is
# listening (the same live-vs-stale distinction fixtures-up uses).
socket_accepts() { # socket_accepts <path>
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(1)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(1)' "$1" 2>/dev/null
}

# Stops whatever herdr server owns 12223's socket (pidfile owner or a
# bridge-auto-started stray), waits for it to release the socket, then
# clears the socket files and pidfile — the deterministic "no server on
# 12223" state the test's gate checks.
reconcile_12223() {
  local sdir="$RUN/herdr/server-12223"
  if [ -f "$sdir/server.pid" ]; then
    kill "$(cat "$sdir/server.pid")" 2>/dev/null || true
  fi
  (cd "$sdir" && HERDR_SOCKET_PATH="$sdir/herdr.sock" HOME="$sdir/home" \
    "$HERDR_BIN" server stop >/dev/null 2>&1) || true
  local deadline=$((SECONDS + 5))
  while [ $SECONDS -lt $deadline ] && [ -S "$sdir/herdr.sock" ] \
    && socket_accepts "$sdir/herdr.sock"; do
    sleep 0.1
  done
  rm -f "$sdir/herdr.sock" "$sdir/herdr-client.sock" "$sdir/server.pid"
}

# The test's own gate, checked host-side: 12222's client socket present
# AND 12223's absent. 12222 is probed for liveness (not just file
# existence) because a stale pidfile naming a recycled pid makes
# fixtures-up believe a dead server is running.
missing_server_state_holds() {
  [ -S "$RUN/herdr/server-12222/herdr-client.sock" ] \
    && socket_accepts "$RUN/herdr/server-12222/herdr-client.sock" \
    && [ ! -e "$RUN/herdr/server-12223/herdr-client.sock" ]
}

# Brings 12222's herdr server back when its socket is dead: drop any
# pidfile whose owner is not serving, then let fixtures-up (re)start it.
ensure_12222_up() {
  local sdir="$RUN/herdr/server-12222"
  if ! socket_accepts "$sdir/herdr-client.sock"; then
    if [ -f "$sdir/server.pid" ]; then
      kill "$(cat "$sdir/server.pid")" 2>/dev/null || true
      rm -f "$sdir/server.pid"
    fi
    rm -f "$sdir/herdr.sock" "$sdir/herdr-client.sock"
    HERDR_SERVERS=12222 scripts/fixtures-up.sh
  fi
}

restore_topology() {
  # The test's bridge may have auto-started a pidfile-less server on 12223;
  # reconcile first so fixtures-up spawns fresh owners with true pidfiles.
  reconcile_12223
  scripts/fixtures-up.sh
}

trap restore_topology EXIT

echo "== flipping topology: herdr server on 12222 only =="
ensure_12222_up
attempts=0
until missing_server_state_holds; do
  attempts=$((attempts + 1))
  if [ "$attempts" -gt 3 ]; then
    echo "FAIL: could not establish the missing-server topology " \
         "(12222 up, 12223 down) after $attempts attempts — aborting so the" \
         "test fails loudly instead of silently skipping"
    exit 1
  fi
  echo "topology not yet in the missing-server state (attempt $attempts); reconciling 12223"
  reconcile_12223
  ensure_12222_up
  sleep 1
done
echo "topology verified: herdr server on 12222 only"

echo "== running testMissingHerdrServerReachesTypedEmbedState =="
xcodebuild test -scheme BicTerm \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:BicTermUITests/HerdrConnectUITests/testMissingHerdrServerReachesTypedEmbedState \
  2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

# A skip is a failure for this wrapper: the whole point is executing the test.
if grep -q "testMissingHerdrServerReachesTypedEmbedState\]' skipped" "$LOG"; then
  echo "FAIL: the test SKIPPED — the topology was wrong at gate time (see above)"
  status=1
fi

echo "== restoring standard topology (herdr on 12222 + 12223) =="
restore_topology
trap - EXIT

if [ "$status" -eq 0 ] && grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG"; then
  echo "herdr-missing-server: PASS (log: $LOG)"
  exit 0
fi
echo "herdr-missing-server: FAIL (log: $LOG)"
exit "${status:-1}"
