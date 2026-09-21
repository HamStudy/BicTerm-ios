#!/bin/bash
# BicTerm fixtures: bring up hop-1 sshd (12222), hop-2 sshd (12223), a
# UDS forwarder on loopback, and (when fetched) one headless herdr server
# per fixture port. Idempotent. Self-checks run at the end;
# exits non-zero if any check fails.
#
# Env knobs:
#   HOP1_ALT_KEY=1   start hop-1 with the ALTERNATE host key (hop1_config.alt)
#                    — used by T7's changed-host-key test.
#   HERDR_SERVERS    space-separated fixture ports that get a herdr server
#                    (default "12222 12223"; set EMPTY to start none — the
#                    missing-server diagnostic scenarios).
#   HERDR_LOSSY      space-separated lossy-proxy entries "LISTEN[@TARGET]:opts"
#                    (opts: drop=<n>pct,delay=<n>ms,dupe=<n>pct; target defaults
#                    to 12222). Default: no proxy. See Fixtures/bin/lossy-proxy.py.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Fixtures"
RUN="$FIX/run"
KEYS="$FIX/keys"
SSHD_DIR="$FIX/sshd"
# Trailing slash anchors each match to a path boundary: "/BicTerm/" must never
# match a "/BicTerm-ios/" checkout or every run appends another "-ios". The
# committed configs carry the neutral placeholder prefix "/Users/localdev/";
# this sed rewrites it to "$ROOT/" so sshd gets this checkout's absolute paths
# (a runtime-only change; never commit the rewritten configs). The second
# pattern also normalizes configs still carrying the legacy non-ios checkout
# prefix; rewriting to "$ROOT/" in the checkout a path already names is a no-op.
OLD_PATH_PREFIX="/Users/localdev/code/BicTerm/"
OLD_PATH_PREFIX_IOS="/Users/localdev/code/BicTerm-ios/"

mkdir -p "$RUN" "$SSHD_DIR/host_keys" "$SSHD_DIR/host_key_alt"

# ---- 1. Rewrite committed configs to this checkout's absolute paths --------
for cfg in hop1_config hop1_config.alt hop2_config; do
  if [ -f "$SSHD_DIR/$cfg" ]; then
    sed -i '' -e "s|$OLD_PATH_PREFIX_IOS|$ROOT/|g" -e "s|$OLD_PATH_PREFIX|$ROOT/|g" "$SSHD_DIR/$cfg"
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

# ---- 4.5 herdr servers (one per fixture sshd port; isolated state) -----------
# Headless start command, discovered from the binary's own help output:
#   herdr --help   -> "herdr server    Run as headless server"
#   herdr server --help lists the subcommands (stop, reload-config, ...);
#   bare `herdr server` is exactly what herdr's own daemon spawner execs.
# Each instance runs with its own HERDR_SOCKET_PATH and HOME under
# Fixtures/run/herdr/server-<port>/ so the two fixture servers cannot
# collide with each other (or with a real user herdr). The sshd fixture
# configs SetEnv the same HERDR_SOCKET_PATH so the FIXED bridge command
# (`exec '<path>' remote-client-bridge`, HerdrCommandBuilder) resolves the
# per-port fixture server without any env prefix in the command string.
HERDR_BIN="$RUN/herdr/herdr"
# `${VAR-default}` (not `:-`): an explicitly EMPTY HERDR_SERVERS starts zero
# servers — the missing-server diagnostic scenarios.
HERDR_SERVERS="${HERDR_SERVERS-12222 12223}"
# Stop any fixture herdr server whose port is NOT selected this run, so the
# knob is deterministic ("exactly these ports have servers"). Only pidfiles
# under Fixtures/run/herdr/server-*/ are ever touched — never a user herdr.
if [ -x "$HERDR_BIN" ] || [ -d "$RUN/herdr" ]; then
  for spid in "$RUN"/herdr/server-*/server.pid; do
    [ -f "$spid" ] || continue
    port="$(basename "$(dirname "$spid")")"
    port="${port#server-}"
    case " $HERDR_SERVERS " in
      *" $port "*) continue ;;
    esac
    kill "$(cat "$spid")" 2>/dev/null || true
    rm -f "$spid"
    echo "herdr server :$port not in HERDR_SERVERS; stopped"
  done
fi
if [ ! -x "$HERDR_BIN" ]; then
  echo "WARNING: herdr fixture binary absent ($HERDR_BIN); herdr servers NOT started."
  echo "         Fetch it with scripts/herdr-server-fetch.sh to enable herdr fixture tests;"
  echo "         sshd fixtures remain fully usable without it."
else
  for port in $HERDR_SERVERS; do
    sdir="$RUN/herdr/server-$port"
    spid="$sdir/server.pid"
    if [ -f "$spid" ] && kill -0 "$(cat "$spid")" 2>/dev/null; then
      echo "herdr server :$port already running (pid $(cat "$spid"))"
      continue
    fi
    rm -f "$spid"
    mkdir -p "$sdir/home"
    # nohup + subshell-exit detaches the daemon (reparented to launchd);
    # no disown needed — the job never enters this shell's job table.
    (
      cd "$sdir"
      HERDR_SOCKET_PATH="$sdir/herdr.sock" HOME="$sdir/home" \
        nohup "$HERDR_BIN" server >server.log 2>&1 </dev/null &
      echo $! >server.pid
    )
    # Readiness: poll the client socket the same way herdr's own autodetect
    # does — connect() succeeds iff a server is listening on it.
    herdr_ready=0
    for _ in $(seq 1 150); do
      if python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])' "$sdir/herdr-client.sock" 2>/dev/null; then
        herdr_ready=1; break
      fi
      sleep 0.1
    done
    if [ "$herdr_ready" != "1" ]; then
      echo "FAIL: herdr server :$port did not listen on $sdir/herdr-client.sock within 15s"
      tail -5 "$sdir/server.log" 2>/dev/null
      exit 1
    fi
    echo "herdr server :$port ready (client socket $sdir/herdr-client.sock)"
  done
fi

# ---- 4.6 lossy proxy (terminal sync-integrity fixture, T12) ------------------
# HERDR_LOSSY: space-separated entries "LISTEN[@TARGET]:opt,opt,..." — a
# userspace impairment proxy (Fixtures/bin/lossy-proxy.py; NO pf/dummynet)
# listening on 127.0.0.1:LISTEN and forwarding to the fixture sshd on
# TARGET (default 12222). opts: drop=<n>pct delay=<n>ms dupe=<n>pct.
# Runtime steering: append lines (drop=5pct / delay=200ms / dupe=1pct /
# kill / reset) to Fixtures/run/lossy-proxy-<port>.ctl. Default: none.
LOSSY_PIDS=""
for entry in ${HERDR_LOSSY:-}; do
  spec="${entry%%:*}"
  opts="${entry#*:}"
  [ "$opts" = "$entry" ] && opts=""
  listen="${spec%%@*}"
  target="${spec#*@}"
  [ "$target" = "$spec" ] && target=12222
  proxy_args=""
  for opt in $(echo "$opts" | tr ',' ' '); do
    case "$opt" in
      drop=*|delay=*|dupe=*) proxy_args="$proxy_args --${opt%%=*} ${opt#*=}" ;;
      "") ;;
      *) echo "FAIL: bad HERDR_LOSSY option '$opt' in entry '$entry'"; exit 1 ;;
    esac
  done
  lpid="$RUN/lossy-proxy-$listen.pid"
  if [ -f "$lpid" ] && kill -0 "$(cat "$lpid")" 2>/dev/null; then
    echo "lossy proxy :$listen already running (pid $(cat "$lpid"))"
  else
    rm -f "$lpid" "$RUN/lossy-proxy-$listen.ctl"
    touch "$RUN/lossy-proxy-$listen.ctl"
    nohup python3 "$FIX/bin/lossy-proxy.py" --listen "$listen" \
      --target "127.0.0.1:$target" --control "$RUN/lossy-proxy-$listen.ctl" \
      --log "$RUN/lossy-proxy-$listen.log" $proxy_args \
      </dev/null >>"$RUN/lossy-proxy-$listen.log" 2>&1 &
    echo $! > "$lpid"
    disown 2>/dev/null || true
  fi
  LOSSY_PIDS="$LOSSY_PIDS $lpid"
done

# pids manifest (for fixtures-down.sh)
{
  cat "$RUN/hop1.pid" 2>/dev/null
  cat "$RUN/hop2.pid" 2>/dev/null
  cat "$UDS_PIDFILE" 2>/dev/null
  for lpid in $LOSSY_PIDS; do cat "$lpid" 2>/dev/null; done
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

for entry in ${HERDR_LOSSY:-}; do
  listen="${entry%%:*}"
  listen="${listen%%@*}"
  wait_port "$listen" "lossy-proxy-$listen"
done

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
  -p 22 -o "ProxyCommand=/usr/bin/nc -U $UDS_SOCK" "$WHO@bicterm-uds.invalid" \
  'printf bicterm-uds-ok' </dev/null 2>/dev/null)
check "UDS-bridged ssh prints bicterm-uds-ok" "bicterm-uds-ok" "$out"

perms=$(stat -f %Lp "$UDS_SOCK" 2>/dev/null)
check "UDS socket permissions are 600" "600" "$perms"

# Lossy proxy must carry a full SSH session end-to-end (impairments only
# stall TCP, which retransmits). Retry: a burst-y drop setting can make a
# single attempt slow enough to hit the outer probe timeout.
for entry in ${HERDR_LOSSY:-}; do
  listen="${entry%%:*}"
  listen="${listen%%@*}"
  proxy_ok=""
  for _ in 1 2 3; do
    out=$(/usr/bin/ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=15 \
      -i "$KEYS/bicterm-fixture-ed25519" -p "$listen" "$WHO@127.0.0.1" \
      'printf bicterm-lossy-ok' </dev/null 2>/dev/null)
    if [ "$out" = "bicterm-lossy-ok" ]; then proxy_ok=1; break; fi
    sleep 1
  done
  check "lossy proxy :$listen carries an ssh session" "1" "${proxy_ok:-0}"
done

echo "---"
if [ "$FAILURES" -gt 0 ]; then
  echo "fixtures-up: $FAILURES self-check(s) FAILED"
  exit 1
fi
echo "fixtures-up: all self-checks passed (hop1=$HOP1_CONFIG)"
exit 0
