#!/bin/bash
# test-core.sh — runs BicTermCore unit tests on the iPhone simulator.
#
# How: xcodebuild runs the Swift package's auto-generated "BicTermCore" scheme
# from the package directory (SPM packages expose a scheme per package by
# default). Full xcodebuild log is teed to
# .sisyphus/evidence/task-1-xcodebuild.log; exit status is xcodebuild's.
set -o pipefail
cd "$(dirname "$0")/../BicTermCore"

DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
LOG="../.sisyphus/evidence/task-1-xcodebuild.log"
mkdir -p "../.sisyphus/evidence"

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild test -scheme BicTermCore -destination "$DEST" 2>&1 | tee "$LOG" | xcbeautify
    status=${PIPESTATUS[0]}
else
    xcodebuild test -scheme BicTermCore -destination "$DEST" 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
fi

if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG"; then
    echo "check: '** TEST SUCCEEDED **' present in $LOG"
else
    echo "check FAILED: '** TEST SUCCEEDED **' not found in $LOG"
    [ "$status" -eq 0 ] && status=1
fi
exit "$status"
