#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home" XDG_CACHE_HOME="$ROOT/.build-artifacts/Home/.cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-artifacts/ModuleCache"
options=(--parameter multi_agent=true --parameter script_mode=normal --parameter start_blocks_login=true)
bash scripts/coder-acceptance-up.sh g12-selection "${options[@]}"
ruby scripts/coder-acceptance-state.rb g12-selection --wait-connected \
    | tee .sisyphus/evidence/phase2-g12-b-selection-previous.log \
    > Fixtures/run/coder-acceptance/g12-selection/previous-state.json
bash scripts/coder-acceptance-up.sh g12-selection "${options[@]}"
ruby scripts/coder-acceptance-state.rb g12-selection --wait-connected \
    > .sisyphus/evidence/phase2-g12-b-selection-current.log
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' \
    DERIVED_DATA="$ROOT/.build-artifacts/DerivedData/g12-core" \
    ONLY_TESTING='BicTermCoreTests/CoderNativeSelectionAcceptanceTests' \
    EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-b-selection-acceptance.log' \
    scripts/test-core.sh
