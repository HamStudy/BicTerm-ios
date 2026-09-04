#!/bin/bash
# test-ui.sh — runs BicTermUITests on the iPad simulator against the
# BicTerm app scheme (generated from project.yml by xcodegen).
# Full log is teed to .sisyphus/evidence/task-1-uitest.log; exit status is
# xcodebuild's.
set -o pipefail
cd "$(dirname "$0")/.."

DEST='platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1'
LOG=".sisyphus/evidence/task-1-uitest.log"
mkdir -p .sisyphus/evidence

# -skipPackagePluginValidation/-skipMacroValidation: SwiftTerm ships a
# build-tool plugin; headless xcodebuild cannot prompt for plugin trust.
FLAGS=(-skipPackagePluginValidation -skipMacroValidation)

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild test -scheme BicTerm -destination "$DEST" "${FLAGS[@]}" 2>&1 | tee "$LOG" | xcbeautify
    status=${PIPESTATUS[0]}
else
    xcodebuild test -scheme BicTerm -destination "$DEST" "${FLAGS[@]}" 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
fi

if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG"; then
    echo "check: '** TEST SUCCEEDED **' present in $LOG"
else
    echo "check FAILED: '** TEST SUCCEEDED **' not found in $LOG"
    [ "$status" -eq 0 ] && status=1
fi
exit "$status"
