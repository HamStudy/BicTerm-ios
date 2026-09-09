#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CODER_CONFIG_DIR="$ROOT/Fixtures/run/coder-dev/config"
export CODER_CACHE_DIRECTORY="$ROOT/Fixtures/run/coder-dev/cache"
export CODER_USE_KEYRING=false
set -a
source Fixtures/run/coder-dev.env
set +a
name="${1:-g12-selection}"
if [ "$#" -gt 0 ]; then shift; fi
[[ "$name" =~ ^g12-[a-z0-9-]+$ ]] || { printf 'Invalid acceptance workspace name\n' >&2; exit 1; }
coder="$ROOT/Fixtures/run/coder-bin/coder"
base="$ROOT/Fixtures/run/coder-acceptance/$name"
"$coder" templates push bicterm-acceptance -d Fixtures/coder/acceptance-template --yes --activate
state="$(CODER_ACCEPTANCE_NAME="$name" ruby -rjson -rnet/http -e '
url = URI(ENV.fetch("CODER_URL"))
request = Net::HTTP::Get.new("/api/v2/workspaces?q=owner:me")
request["Coder-Session-Token"] = ENV.fetch("CODER_SESSION_TOKEN")
response = Net::HTTP.start(url.host, url.port, nil, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
abort "workspace discovery failed" unless response.code == "200"
puts JSON.parse(response.body).fetch("workspaces").any? { |workspace| workspace.fetch("name") == ENV.fetch("CODER_ACCEPTANCE_NAME") } ? "present" : "missing"
')"
if [ "$state" = missing ]; then
    "$coder" create "$name" --template bicterm-acceptance --yes "$@" </dev/null
else
    "$coder" update "$name" "$@" </dev/null
fi
for agent in main sidecar; do
    script="$base/$agent.sh"
    if [ ! -f "$script" ]; then continue; fi
    pid_file="$base/$agent.pid"
    if [ -f "$pid_file" ]; then
        read -r pid < "$pid_file"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            for attempt in {1..100}; do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                printf 'Old acceptance agent did not stop\n' >&2
                exit 1
            fi
        fi
    fi
    /bin/bash "$script" </dev/null >> "$base/$agent.log" 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
done
printf 'Acceptance workspace %s provisioned; agent processes launched\n' "$name"
