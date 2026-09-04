#!/bin/bash
# test-ui.sh — runs BicTermUITests on the iPad simulator against the
# BicTerm app scheme (generated from project.yml by xcodegen).
# Full log is teed to the path in EVIDENCE_LOG (or the default); exit status is
# xcodebuild's.
#
# ---------------------------------------------------------------------------
# Environment-variable overrides for parallel execution (all OPTIONAL):
#
#   DEST_OVERRIDE   Replaces the full -destination string. Example:
#     DEST_OVERRIDE='platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1'
#
#   DERIVED_DATA    When set, adds -derivedDataPath "$DERIVED_DATA". Example:
#     DERIVED_DATA=/tmp/BicTerm-DD-override-test
#
#   ONLY_TESTING    When set, adds -only-testing:"$ONLY_TESTING". Example:
#     ONLY_TESTING=BicTermUITests/SmokeTests
#
#   EVIDENCE_LOG    Replaces the tee'd log path (default: task-1-uitest.log).
#     EVIDENCE_LOG=.sisyphus/evidence/my-custom.log
#
# Smoke-run example with all overrides:
#   DERIVED_DATA=/tmp/BicTerm-DD-override-test \
#     ONLY_TESTING=BicTermUITests/SmokeTests \
#     EVIDENCE_LOG=.sisyphus/evidence/override-smoke.log \
#     scripts/test-ui.sh
# ---------------------------------------------------------------------------
set -o pipefail

# Resolve REPO_ROOT before we cd into BicTermCore so that relative
# EVIDENCE_LOG paths (e.g. .sisyphus/evidence/my.log) are anchored to
# the repo root, not to the BicTermCore subdirectory.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEST_DEFAULT='platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1'
LOG_DEFAULT="$REPO_ROOT/.sisyphus/evidence/task-1-uitest.log"
mkdir -p "$REPO_ROOT/.sisyphus/evidence"

# Apply env overrides; defaults preserved when vars are unset/empty.
DEST="${DEST_OVERRIDE:-${DEST_DEFAULT}}"
# If EVIDENCE_LOG is set and relative, anchor it to REPO_ROOT.
if [[ -n "${EVIDENCE_LOG:-}" ]]; then
    case "$EVIDENCE_LOG" in
        /*) LOG="$EVIDENCE_LOG" ;;
        *)  LOG="$REPO_ROOT/$EVIDENCE_LOG" ;;
    esac
else
    LOG="$LOG_DEFAULT"
fi

# Build xcodebuild args as an array so conditionals compose cleanly.
XB_ARGS=(
    test
    -scheme BicTerm
    -destination "$DEST"
    -skipPackagePluginValidation
    -skipMacroValidation
)
if [[ -n "${DERIVED_DATA:-}" ]]; then
    XB_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -n "${ONLY_TESTING:-}" ]]; then
    XB_ARGS+=(-only-testing:"$ONLY_TESTING")
fi

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${XB_ARGS[@]}" 2>&1 | tee "$LOG" | xcbeautify
    status=${PIPESTATUS[0]}
else
    xcodebuild "${XB_ARGS[@]}" 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
fi

if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG"; then
    echo "check: '** TEST SUCCEEDED **' present in $LOG"
else
    echo "check FAILED: '** TEST SUCCEEDED **' not found in $LOG"
    [ "$status" -eq 0 ] && status=1
fi
exit "$status"