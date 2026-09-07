#!/bin/bash
# coder-dev-up.sh — bring up the NATIVE Coder dev-server fixture on
# 127.0.0.1:7080 (no Docker anywhere in the flow), create the first user via
# the API, push the committed bicterm-host template, create a running workspace
# ("bicterm-host", agent started natively on this host) plus a stopped one
# ("bicterm-stopped"), and run self-checks.
#
# Idempotent: safe to re-run while the fixture is already up. Credentials are
# never placed on any command line — they travel via environment, stdin, or
# the 0600 env file at Fixtures/run/coder-dev.env.
#
# Note: coder v2.36.4 has no literal `--dev` flag; the dev-deployment form of
# this version is `coder server` without --postgres-url (built-in PostgreSQL,
# all state under CODER_CONFIG_DIR) on a loopback --http-address/--access-url.
#
# Output is teed to .sisyphus/evidence/phase2-g6-fixture-up.log. The script
# never echoes secrets; the tee stream is additionally filtered through a
# redacter that masks the fixture password/token should they ever leak.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Fixtures"
RUN="$FIX/run"
DEV="$RUN/coder-dev"
BIN_DIR="$RUN/coder-bin"
CODER="$BIN_DIR/coder"
OLD_PATH_PREFIX="/Users/richard/code/BicTerm"

ADDR="127.0.0.1:7080"
BASE_URL="http://$ADDR"
ENV_FILE="$RUN/coder-dev.env"

CODER_VERSION="2.36.4"
ARCHIVE="coder_${CODER_VERSION}_darwin_arm64.zip"
RELEASE_BASE="https://github.com/coder/coder/releases/download/v${CODER_VERSION}"
# sha256 of coder_2.36.4_darwin_arm64.zip (cross-checked against the release's
# coder_2.36.4_checksums.txt on every download).
EXPECTED_SHA256="5b7bfd3ad4af63199eb65c3a0cc94bf475ee196bc925af4dbf0e0c658dc79bdf"

FIXTURE_EMAIL="fixture@coder-dev.bicterm.local"
FIXTURE_USERNAME="coder-fixture"

EVIDENCE_DIR="$ROOT/.sisyphus/evidence"
LOG="$EVIDENCE_DIR/phase2-g6-fixture-up.log"
mkdir -p "$EVIDENCE_DIR" "$RUN" "$DEV/config" "$DEV/cache" "$DEV/agents" "$DEV/tmp" "$DEV/template" "$BIN_DIR"
: >"$LOG"

# Redacting tee: secret values arrive via env after creation; the filter masks
# them if they ever appear in output.
exec > >(
  python3 -c '
import sys, os
def secrets():
    out = set()
    for k in ("FIXTURE_PASSWORD", "CODER_SESSION_TOKEN"):
        v = os.environ.get(k, "")
        if v:
            out.add(v)
    ef = os.environ.get("FIXTURE_ENV_FILE", "")
    if ef and os.path.exists(ef):
        try:
            with open(ef) as f:
                for line in f:
                    if line.startswith(("CODER_SESSION_TOKEN=", "CODER_FIXTURE_PASSWORD=")):
                        out.add(line.strip().split("=", 1)[1])
        except OSError:
            pass
    return out
while True:
    line = sys.stdin.readline()
    if not line:
        break
    for s in secrets():
        line = line.replace(s, "<redacted>")
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee -a "$LOG"
) 2>&1
export FIXTURE_ENV_FILE="$ENV_FILE"

START_EPOCH=$(python3 -c 'import time; print(int(time.time()))')

die() { echo "FAIL: $*" >&2; exit 1; }

elapsed() {
  python3 -c "import time; print(int(time.time()) - $START_EPOCH)"
}

# ---------------------------------------------------------------------------
# 1. Binary: download pinned release, verify sha256 twice (embedded constant
#    AND release checksums file), unzip.
# ---------------------------------------------------------------------------
zip_path="$BIN_DIR/$ARCHIVE"
checksums_path="$BIN_DIR/coder_${CODER_VERSION}_checksums.txt"

actual_sha() { shasum -a 256 "$1" | awk '{print $1}'; }

if [ -x "$CODER" ] && [ -f "$zip_path" ] && [ "$(actual_sha "$zip_path")" = "$EXPECTED_SHA256" ]; then
  echo "binary: pinned coder v$CODER_VERSION already present and verified"
else
  rm -f "$CODER"
  echo "binary: downloading $ARCHIVE"
  curl -fsSL --retry 3 -o "$zip_path" "$RELEASE_BASE/$ARCHIVE"
  curl -fsSL --retry 3 -o "$checksums_path" "$RELEASE_BASE/coder_${CODER_VERSION}_checksums.txt"

  got="$(actual_sha "$zip_path")"
  release_sha="$(awk -v f="$ARCHIVE" '$2 == f {print $1}' "$checksums_path")"
  [ -n "$release_sha" ] || die "archname $ARCHIVE not found in checksums file"
  [ "$release_sha" = "$EXPECTED_SHA256" ] || die "release checksum ($release_sha) != embedded pin ($EXPECTED_SHA256)"
  [ "$got" = "$EXPECTED_SHA256" ] || die "downloaded sha256 mismatch: got $got"
  unzip -o -q "$zip_path" -d "$BIN_DIR"
  chmod +x "$CODER"
  echo "binary: sha256 verified against embedded pin + release checksums"
fi
[ -x "$CODER" ] || die "coder binary missing at $CODER"

# ---------------------------------------------------------------------------
# 2. Server: native background process, ALL fds redirected (T5 sshd pattern).
# ---------------------------------------------------------------------------
server_alive() {
  [ -f "$DEV/server.pid" ] && kill -0 "$(cat "$DEV/server.pid")" 2>/dev/null
}

start_server() {
  if server_alive; then
    echo "server: already running (pid $(cat "$DEV/server.pid"))"
    return 0
  fi
  rm -f "$DEV/server.pid"
  env CODER_CONFIG_DIR="$DEV/config" \
      CODER_CACHE_DIRECTORY="$DEV/cache" \
      TMPDIR="$DEV/tmp" \
      "$CODER" server \
        --http-address "$ADDR" \
        --access-url "$BASE_URL" \
        --update-check=false \
        --derp-server-stun-addresses disable \
        --stats-collection-usage-stats-enable=false \
        </dev/null >>"$DEV/server.log" 2>&1 &
  echo $! >"$DEV/server.pid"
  disown 2>/dev/null || true
  echo "server: launched (pid $(cat "$DEV/server.pid")), waiting for buildinfo"
}

wait_buildinfo() {
  local i
  for i in $(seq 1 240); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/buildinfo" 2>/dev/null || true)" = "200" ]; then
      echo "server: buildinfo 200 after $((i / 2))s"
      return 0
    fi
    if ! server_alive; then
      echo "server: process died; last log lines:"
      tail -20 "$DEV/server.log" || true
      return 1
    fi
    sleep 0.5
  done
  echo "server: buildinfo did not return 200 within 120s"
  return 1
}

start_server
wait_buildinfo || die "coder server failed to become ready"

# ---------------------------------------------------------------------------
# 3. First user via API (JSON built by python via env, curl reads stdin).
# ---------------------------------------------------------------------------
api_get_code() { # api_get_code <path> [token]  — token travels via stdin config, never argv
  if [ -n "${2:-}" ]; then
    printf 'header = "Coder-Session-Token: %s"\n' "$2" | \
      curl -s -o /dev/null -w '%{http_code}' -K - "$BASE_URL$1"
  else
    curl -s -o /dev/null -w '%{http_code}' "$BASE_URL$1"
  fi
}

token_valid() {
  [ -f "$ENV_FILE" ] || return 1
  local tok
  tok="$(grep '^CODER_SESSION_TOKEN=' "$ENV_FILE" | sed 's/^CODER_SESSION_TOKEN=//')"
  [ -n "$tok" ] || return 1
  [ "$(api_get_code /api/v2/users/me "$tok")" = "200" ]
}

json_body() { # json_body <email> <username> <password-env-name> [mode]
  FIXTURE_EMAIL_ARG="$1" FIXTURE_USERNAME_ARG="$2" FIXTURE_MODE_ARG="${4:-first}" \
    python3 -c '
import json, os
email = os.environ["FIXTURE_EMAIL_ARG"]
mode = os.environ["FIXTURE_MODE_ARG"]
if mode == "first":
    print(json.dumps({
        "email": email,
        "username": os.environ["FIXTURE_USERNAME_ARG"],
        "password": os.environ["FIXTURE_PASSWORD"],
        "trial": False,
    }), end="")
elif mode == "login":
    print(json.dumps({
        "email": email,
        "password": os.environ["FIXTURE_PASSWORD"],
    }), end="")
'
}

login_and_save_env() {
  local body code token
  body="$(FIXTURE_PASSWORD="$FIXTURE_PASSWORD_VALUE" json_body "$FIXTURE_EMAIL" "$FIXTURE_USERNAME" login)"
  code="$(printf '%s' "$body" | curl -s -o "$DEV/login-response.json" -w '%{http_code}' \
          -X POST "$BASE_URL/api/v2/users/login" \
          -H 'Content-Type: application/json' --data @-)"
  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    rm -f "$DEV/login-response.json"
    die "login failed (http $code)"
  fi
  token="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)["session_token"], end="")
' "$DEV/login-response.json")"
  rm -f "$DEV/login-response.json"
  [ -n "$token" ] || die "login response had no session_token"
  umask 077
  {
    printf 'CODER_URL=%s\n' "$BASE_URL"
    printf 'CODER_SESSION_TOKEN=%s\n' "$token"
    printf 'CODER_FIXTURE_EMAIL=%s\n' "$FIXTURE_EMAIL"
    printf 'CODER_FIXTURE_USERNAME=%s\n' "$FIXTURE_USERNAME"
    printf 'CODER_FIXTURE_PASSWORD=%s\n' "$FIXTURE_PASSWORD_VALUE"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "auth: session token stored (0600) at Fixtures/run/coder-dev.env"
}

if token_valid; then
  echo "auth: existing token in coder-dev.env still valid; resuming"
else
  FIXTURE_PASSWORD_VALUE="$(openssl rand -base64 12 | tr -d '\n')"
  echo "auth: creating first user (password generated, never echoed)"
  export FIXTURE_PASSWORD="$FIXTURE_PASSWORD_VALUE"
  body="$(json_body "$FIXTURE_EMAIL" "$FIXTURE_USERNAME" first)"
  unset FIXTURE_PASSWORD
  code="$(printf '%s' "$body" | curl -s -o /dev/null -w '%{http_code}' \
          -X POST "$BASE_URL/api/v2/users/first" \
          -H 'Content-Type: application/json' --data @-)"
  if [ "$code" = "201" ]; then
    login_and_save_env
  elif [ "$code" = "409" ]; then
    echo "auth: server already has a first user; re-logging in with stored password"
    [ -f "$ENV_FILE" ] || die "first user exists but no local env file; run scripts/coder-dev-down.sh to reset"
    FIXTURE_PASSWORD_VALUE="$(grep '^CODER_FIXTURE_PASSWORD=' "$ENV_FILE" | sed 's/^CODER_FIXTURE_PASSWORD=//')"
    [ -n "$FIXTURE_PASSWORD_VALUE" ] || die "env file lacks CODER_FIXTURE_PASSWORD; run scripts/coder-dev-down.sh to reset"
    login_and_save_env
  else
    die "first user creation failed (http $code)"
  fi
fi

# Fixture CLI environment: credentials reach the CLI via env only.
cli_env() {
  set -a
  . "$ENV_FILE"
  set +a
  export CODER_USE_KEYRING=false
  export CODER_CONFIG_DIR="$DEV/config"
  export CODER_CACHE_DIRECTORY="$DEV/cache"
  export TMPDIR="$DEV/tmp"
}

# ---------------------------------------------------------------------------
# 4. Template: materialize path-rewritten runtime copy, push as bicterm-host.
# ---------------------------------------------------------------------------
sed "s|$OLD_PATH_PREFIX|$ROOT|g" "$FIX/coder/template/main.tf" >"$DEV/template/main.tf"

( cli_env; "$CODER" templates push bicterm-host -d "$DEV/template" --yes --activate ) || die "template push failed"
echo "template: bicterm-host pushed"

# ---------------------------------------------------------------------------
# 5. Workspaces: bicterm-host (running, agent on host) + bicterm-stopped.
# ---------------------------------------------------------------------------
workspace_state() { # workspace_state <name> -> prints "exists|missing build_status agent_statuses"
  WORKSPACE_NAME_ARG="$1" CODER_SESSION_TOKEN_ARG="$(grep '^CODER_SESSION_TOKEN=' "$ENV_FILE" | sed 's/^CODER_SESSION_TOKEN=//')" \
  python3 -c '
import json, os, urllib.request
name = os.environ["WORKSPACE_NAME_ARG"]
req = urllib.request.Request(
    "'"$BASE_URL"'/api/v2/workspaces?q=owner:me&limit=100&offset=0",
    headers={"Coder-Session-Token": os.environ["CODER_SESSION_TOKEN_ARG"]})
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
for ws in data.get("workspaces", []):
    if ws.get("name") == name:
        lb = ws.get("latest_build") or {}
        agents = []
        for r in lb.get("resources") or []:
            for a in (r.get("agents") or []):
                agents.append(a.get("status") or "")
        print("exists", lb.get("transition") or "", lb.get("status") or "", ",".join(agents))
        break
else:
    print("missing")
'
}

create_workspace() { # create_workspace <name>
  local name="$1"
  if [ "$(workspace_state "$name" | cut -d' ' -f1)" = "exists" ]; then
    echo "workspace: $name already exists"
    return 0
  fi
  echo "workspace: creating $name from template bicterm-host"
  ( cli_env; "$CODER" create "$name" --template bicterm-host --yes ) </dev/null || die "workspace create failed: $name"
}

start_host_agent() {
  local script="$DEV/agents/bicterm-host.sh"
  local pidfile="$DEV/agents/bicterm-host.pid"
  [ -f "$script" ] || die "agent start script $script not written by provisioner"
  chmod 700 "$script"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "agent: bicterm-host agent already running (pid $(cat "$pidfile"))"
    return 0
  fi
  env TMPDIR="$DEV/tmp" "$script" </dev/null >>"$DEV/agents/bicterm-host.log" 2>&1 &
  echo $! >"$pidfile"
  disown 2>/dev/null || true
  echo "agent: bicterm-host agent launched (pid $(cat "$pidfile"))"
}

wait_agent_connected() {
  local i state
  for i in $(seq 1 180); do
    state="$(workspace_state bicterm-host)"
    case "$state" in
      "exists start running "*connected*)
        echo "agent: connected (after $((i * 2))s)"
        return 0
        ;;
    esac
    sleep 2
  done
  echo "agent: not connected within 360s; last state: $state"
  return 1
}

create_workspace bicterm-host
start_host_agent
wait_agent_connected || die "bicterm-host agent did not connect"

create_workspace bicterm-stopped
if [ "$(workspace_state bicterm-stopped | awk '{print $2,$3}')" != "stop stopped" ]; then
  ( cli_env; "$CODER" stop bicterm-stopped --yes ) </dev/null || die "stop bicterm-stopped failed"
  for i in $(seq 1 60); do
    [ "$(workspace_state bicterm-stopped | awk '{print $2,$3}')" = "stop stopped" ] && break
    sleep 2
  done
fi
[ "$(workspace_state bicterm-stopped | awk '{print $2,$3}')" = "stop stopped" ] \
  || die "bicterm-stopped did not reach stop/stopped"
echo "workspace: bicterm-stopped is stopped"

# ---------------------------------------------------------------------------
# 6. Self-checks.
# ---------------------------------------------------------------------------
FAILURES=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected [$2], got [$3])"
    FAILURES=$((FAILURES + 1))
  fi
}

TOKEN="$(grep '^CODER_SESSION_TOKEN=' "$ENV_FILE" | sed 's/^CODER_SESSION_TOKEN=//')"
check "env file mode is 0600" "600" "$(stat -f %Lp "$ENV_FILE")"
check "GET /api/v2/users/me with token" "200" "$(api_get_code /api/v2/users/me "$TOKEN")"

buildinfo="$(curl -s "$BASE_URL/api/v2/buildinfo")"
server_version="$(printf '%s' "$buildinfo" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""), end="")')"
echo "buildinfo: $server_version"
case "$server_version" in
  v2.36.4*) check "buildinfo records pinned server version" "ok" "ok" ;;
  *)        check "buildinfo records pinned server version" "ok" "bad:$server_version" ;;
esac

host_state="$(workspace_state bicterm-host)"
case "$host_state" in
  "exists start running "*connected*) check "workspace bicterm-host running with agent connected" "ok" "ok" ;;
  *) check "workspace bicterm-host running with agent connected" "ok" "bad:$host_state" ;;
esac

stopped_state="$(workspace_state bicterm-stopped)"
case "$stopped_state" in
  "exists stop stopped"*) check "workspace bicterm-stopped stopped" "ok" "ok" ;;
  *) check "workspace bicterm-stopped stopped" "ok" "bad:$stopped_state" ;;
esac

WSCOUNT="$(TOKEN_ARG="$TOKEN" python3 -c '
import json, os, urllib.request
req = urllib.request.Request(
    "'"$BASE_URL"'/api/v2/workspaces?q=owner:me&limit=100&offset=0",
    headers={"Coder-Session-Token": os.environ["TOKEN_ARG"]})
with urllib.request.urlopen(req) as resp:
    print(len(json.load(resp).get("workspaces", [])), end="")
')"
echo "workspaces: $WSCOUNT present (bicterm-host running, bicterm-stopped stopped)"

echo "---"
echo "elapsed: $(elapsed)s"
if [ "$FAILURES" -gt 0 ]; then
  echo "coder-dev-up: $FAILURES self-check(s) FAILED"
  exit 1
fi
echo "coder-dev-up: all self-checks passed (server on $ADDR)"
exit 0
