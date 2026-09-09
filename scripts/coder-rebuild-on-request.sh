#!/bin/bash
set -euo pipefail
base='Fixtures/run/coder-acceptance/g12-rebuild'
for attempt in {1..1200}; do
    if [ -f "$base/rebuild-request" ]; then
        bash scripts/coder-acceptance-up.sh g12-rebuild --parameter multi_agent=false --parameter script_mode=normal --parameter start_blocks_login=true
        ruby scripts/coder-acceptance-state.rb g12-rebuild --wait-connected
        touch "$base/rebuild-ready"
        exit 0
    fi
    sleep 0.1
done
printf 'Rebuild request deadline exceeded\n' >&2
exit 1
