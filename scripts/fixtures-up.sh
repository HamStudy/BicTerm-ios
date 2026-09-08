#!/bin/bash
# BicTerm fixtures: bring up hop-1 sshd (12222), hop-2 sshd (12223),
# coder stub (18080) on loopback. Idempotent. Self-checks run at the end;
# exits non-zero if any check fails.
#
# Env knobs:
#   HOP1_ALT_KEY=1   start hop-1 with the ALTERNATE host key (hop1_config.alt)
#                    — used by T7's changed-host-key test.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Fixtures"
RUN="$FIX/run"
KEYS="$FIX/keys"
SSHD_DIR="$FIX/sshd"
OLD_PATH_PREFIX="/Users/richard/code/BicTerm"

mkdir -p "$RUN" "$SSHD_DIR/host_keys" "$SSHD_DIR/host_key_alt"

# ---- 1. Rewrite committed configs to this checkout's absolute paths --------
for cfg in hop1_config hop1_config.alt hop2_config; do
  if [ -f "$SSHD_DIR/$cfg" ]; then
    sed -i '' "s|$OLD_PATH_PREFIX|$ROOT|g" "$SSHD_DIR/$cfg"
  fi
done

# ---- 2. Generate any missing keys (committed; regenerated if deleted) ------
gen_key() { # gen_key <path> <type> <args...> <comment>
  local path="$1"; shift
  local type="$1"; shift
  local comment="$1"; shift
  if [ ! -f "$path" ]; then
    ssh-keygen -q -t "$type" "$@" -C "$comment" -f "$path" || { echo "FAIL: keygen $path"; exit 1; }
  fi
}
gen_key "$SSHD_DIR/host_keys/hop1_host_ed25519"     ed25519 -N ""         "bicterm-fixture-hop1-host"
gen_key "$SSHD_DIR/host_keys/hop2_host_ed25519"     ed25519 -N ""         "bicterm-fixture-hop2-host"
gen_key "$SSHD_DIR/host_key_alt/hop1_host_ed25519"  ed25519 -N ""         "bicterm-fixture-hop1-host-alt"
gen_key "$KEYS/bicterm-fixture-ed25519"                  ed25519 -N ""         "bicterm-fixture-ed25519"
gen_key "$KEYS/bicterm-fixture-ed25519_passphrase"       ed25519 -N "testpass" "bicterm-fixture-ed25519-passphrase"
gen_key "$KEYS/bicterm-fixture-ed25519_hop2_unauthorized" ed25519 -N ""        "bicterm-fixture-ed25519-hop2-unauthorized"
gen_key "$KEYS/bicterm-fixture-rsa3072"                  rsa -b 3072 -N ""     "bicterm-fixture-rsa3072"
chmod 600 "$KEYS"/bicterm-fixture-* 2>/dev/null
chmod 644 "$KEYS"/*.pub 2>/dev/null
chmod 600 "$KEYS"/host_keys/*_host_* 2>/dev/null
chmod 600 "$KEYS"/host_key_alt/*_host_* 2>/dev/null

# ---- 3. authorized_keys -----------------------------------------------------
cat "$KEYS/bicterm-fixture-ed25519.pub" \
    "$KEYS/bicterm-fixture-ed25519_passphrase.pub" \
    "$KEYS/bicterm-fixture-ed25519_hop2_unauthorized.pub" > "$SSHD_DIR/authorized_keys_hop1"
cat "$KEYS/bicterm-fixture-ed25519.pub" > "$SSHD_DIR/authorized_keys_hop2"

# ---- 4. Start daemons --------------------------------------------------------
HOP1_CONFIG="hop1_config"
HOP1_HOSTKEY="$SSHD_DIR/host_keys/hop1_host_ed25519"
if [ "${HOP1_ALT_KEY:-0}" = "1" ]; then
  HOP1_CONFIG="hop1_config.alt"
  HOP1_HOSTKEY="$SSHD_DIR/host_key_alt/hop1_host_ed25519"
fi

start_sshd() { # start_sshd <name> <config> <hostkey>
  local name="$1" cfg="$2" hostkey="$3"
  local pidfile="$RUN/$name.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0 # already running
  fi
  rm -f "$pidfile"
  /usr/sbin/sshd -D -e -f "$SSHD_DIR/$cfg" -h "$hostkey" -E "$RUN/$name.log" </dev/null >>"$RUN/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"
  disown "$pid" 2>/dev/null || true
}

# If hop1 is already running under a DIFFERENT config than requested
# (main vs alt host key), restart it so HOP1_ALT_KEY flips take effect.
if [ -f "$RUN/hop1.pid" ] && kill -0 "$(cat "$RUN/hop1.pid")" 2>/dev/null \
   && [ -f "$RUN/hop1.active_config" ] \
   && [ "$(cat "$RUN/hop1.active_config")" != "$HOP1_CONFIG" ]; then
  kill "$(cat "$RUN/hop1.pid")" 2>/dev/null
  rm -f "$RUN/hop1.pid"
  sleep 0.5
fi
start_sshd hop1 "$HOP1_CONFIG" "$HOP1_HOSTKEY"
[ "$HOP1_CONFIG" = "hop1_config.alt" ] && \
  echo "$HOP1_CONFIG" > "$RUN/hop1.active_config" || echo "hop1_config" > "$RUN/hop1.active_config"
start_sshd hop2 hop2_config "$SSHD_DIR/host_keys/hop2_host_ed25519"

# coder stub
STUB_PIDFILE="$RUN/coder_stub.pid"
if [ -f "$STUB_PIDFILE" ] && kill -0 "$(cat "$STUB_PIDFILE")" 2>/dev/null; then
  : # already running
else
  nohup python3 "$FIX/coder/stub.py" </dev/null >>"$RUN/coder_stub.log" 2>&1 &
  echo $! > "$STUB_PIDFILE"
  disown 2>/dev/null || true
fi

# UDS forwarder: bridges sshd-uds.sock -> hop1 (127.0.0.1:12222) so T8 UDS
# dial tests can reach the fixture sshd with key auth. Bridge unlinks a stale
# socket path before binding and removes it on exit.
UDS_PIDFILE="$RUN/uds_forward.pid"
UDS_SOCK="$RUN/sshd-uds.sock"
if [ -f "$UDS_PIDFILE" ] && kill -0 "$(cat "$UDS_PIDFILE")" 2>/dev/null; then
  : # already running
else
  rm -f "$UDS_PIDFILE"
  nohup python3 "$FIX/bin/uds-forward.py" --socket "$UDS_SOCK" --target 127.0.0.1:12222 \
    </dev/null >>"$RUN/uds_forward.log" 2>&1 &
  echo $! > "$UDS_PIDFILE"
  disown 2>/dev/null || true
fi

# pids manifest (for fixtures-down.sh)
{
  cat "$RUN/hop1.pid" 2>/dev/null
  cat "$RUN/hop2.pid" 2>/dev/null
  cat "$STUB_PIDFILE" 2>/dev/null
  cat "$UDS_PIDFILE" 2>/dev/null
} > "$RUN/pids"

# ---- 5. Wait for ports -------------------------------------------------------
wait_port() { # wait_port <port> <name>
  local port="$1" name="$2" i
  for i in $(seq 1 150); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "FAIL: $name port $port did not open within 15s"
  exit 1
}
wait_port 12222 hop1
wait_port 12223 hop2
wait_port 18080 coder-stub

# Wait for the UDS forwarder to accept connections on its socket path.
UDS_SOCK="$RUN/sshd-uds.sock"
uds_ready=0
for _ in $(seq 1 150); do
  if python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])' "$UDS_SOCK" 2>/dev/null; then
    uds_ready=1; break
  fi
  sleep 0.1
done
if [ "$uds_ready" != "1" ]; then
  echo "FAIL: UDS forwarder did not accept on $UDS_SOCK within 15s"
  exit 1
fi

# ---- 6. ssh -J wrapper (macOS quirk; see Fixtures/README.md) -----------------
mkdir -p "$RUN/bin"
cat > "$RUN/bin/ssh" <<WRAP
#!/bin/bash
# Generated by fixtures-up.sh. Translates -J into an explicit ProxyCommand
# carrying fixture options, because the implicit ProxyJump child re-execs
# /usr/bin/ssh and inherits neither -o flags nor a project-local known_hosts.
jump=""
prev_args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -J) jump="\$2"; shift 2 ;;
    *) prev_args+=("\$1"); shift ;;
  esac
done
if [ -n "\$jump" ]; then
  jspec="\$jump"; juser=""; jport="22"
  case "\$jspec" in *@*) juser="\${jspec%%@*}"; jspec="\${jspec#*@}" ;; esac
  case "\$jspec" in *:*) jport="\${jspec##*:}"; jspec="\${jspec%%:*}" ;; esac
  jlogin=(); [ -n "\$juser" ] && jlogin=(-l "\$juser")
  exec /usr/bin/ssh -o "ProxyCommand=/usr/bin/ssh \${jlogin[@]} -p \$jport -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i $KEYS/bicterm-fixture-ed25519 -W '[%h]:%p' \$jspec" "\${prev_args[@]}"
fi
exec /usr/bin/ssh "\${prev_args[@]}"
WRAP
chmod +x "$RUN/bin/ssh"

# ---- 7. Self-checks (the acceptance commands) --------------------------------
FAILURES=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected [$2], got [$3])"
    FAILURES=$((FAILURES + 1))
  fi
}

WHO="$(whoami)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

out=$(/usr/bin/ssh $SSH_OPTS -o BatchMode=yes -i "$KEYS/bicterm-fixture-ed25519" \
  -p 12222 "$WHO@127.0.0.1" 'printf bicterm-ok' </dev/null 2>/dev/null)
check "hop1 direct ssh prints bicterm-ok" "bicterm-ok" "$out"

out=$(PATH="$RUN/bin:$PATH" ssh $SSH_OPTS -J "$WHO@127.0.0.1:12222" \
  -i "$KEYS/bicterm-fixture-ed25519" -p 12223 "$WHO@127.0.0.1" 'printf hop-ok' </dev/null 2>/dev/null)
check "two-hop ssh -J prints hop-ok" "hop-ok" "$out"

# The UDS forwarder must carry a full SSH session from socket entry to hop1.
out=$(/usr/bin/ssh $SSH_OPTS -o BatchMode=yes -i "$KEYS/bicterm-fixture-ed25519" \
  -p 22 -o "ProxyCommand=/usr/bin/nc -U $UDS_SOCK" "$WHO@coder-uds.invalid" \
  'printf bicterm-uds-ok' </dev/null 2>/dev/null)
check "UDS-bridged ssh prints bicterm-uds-ok" "bicterm-uds-ok" "$out"

perms=$(stat -f %Lp "$UDS_SOCK" 2>/dev/null)
check "UDS socket permissions are 600" "600" "$perms"

code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:18080/api/v2/workspaces?q=owner:me")
check "coder stub rejects missing token (401)" "401" "$code"

body=$(curl -s -H "Coder-Session-Token: fixture-token" "http://127.0.0.1:18080/api/v2/workspaces?q=owner:me")
echo "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ws = d.get("workspaces", [])
statuses = [w["latest_build"]["status"] for w in ws]
assert len(ws) >= 2, "need >=2 workspaces"
assert "running" in statuses, "need a running workspace"
assert "stopped" in statuses, "need a stopped workspace"
' && check "coder stub returns workspaces (running+stopped)" "0" "0" || { echo "FAIL: coder stub workspace payload: $body"; FAILURES=$((FAILURES + 1)); }

echo "---"
if [ "$FAILURES" -gt 0 ]; then
  echo "fixtures-up: $FAILURES self-check(s) FAILED"
  exit 1
fi
echo "fixtures-up: all self-checks passed (hop1=$HOP1_CONFIG)"
exit 0
