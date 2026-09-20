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
# The script refuses to start while another xcodebuild is already running
# against the same -destination simulator (see the collision guard below).
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

# ---------------------------------------------------------------------------
# Destination-collision guard.
#
# Two xcodebuild test runs against the same simulator kill each other's
# UI-test runners: each session restarts by force-quitting whatever
# xctrunner is on the device, so the sessions loop until the simulator's
# backboardd dies (the 2026-09-20 iPhone rerun3 "Restarting after
# unexpected exit" storm — 36 restarts, Mach error -308 abort). One suite
# per simulator, always.
#
# Prints the colliding command line and returns 0 when another xcodebuild
# already targets the same destination.
dest_collision() {
    local dest="$1" line pat rest
    pat="-destination ${dest}"
    while IFS= read -r line; do
        [[ "${line%% *}" == *xcodebuild ]] || continue
        [[ "$line" == *"$pat"* ]] || continue
        rest="${line#*"$pat"}"
        # Only a whole -destination argument counts: the destination must
        # be followed by the next flag (" -") or end of line, so
        # "iPhone 17 Pro" never matches a "iPhone 17 Pro Max" run.
        if [[ -z "$rest" || "$rest" == " -"* ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done < <(ps -axo command=)
    return 1
}

colliding="$(dest_collision "$DEST")"
if [[ -n "$colliding" ]]; then
    echo "ERROR: another xcodebuild is already running against destination '$DEST':" >&2
    printf '  %s\n' "$colliding" >&2
    echo "Refusing to start a second suite on the same simulator — concurrent" >&2
    echo "suites force-quit each other's test runners (rerun3 crash storm)." >&2
    echo "Wait for it to finish, or stop it, then re-run." >&2
    exit 1
fi

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