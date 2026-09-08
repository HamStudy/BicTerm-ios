#!/bin/bash
# build-appstore.sh — builds the AppStore flavor of BicTerm: the
# BicTerm-AppStore scheme, which never lists the CoderTunnel target, in a
# configuration (AppStore-Debug/AppStore-Release) that carries no CODER_TUNNEL
# compilation flag and no `-framework CoderTunnel` link flag. The result is an
# .app tree containing zero AGPL-derived (CoderNet-derived) code.
#
# Usage:
#   scripts/build-appstore.sh [AppStore-Release|AppStore-Debug] [evidence-log]
#
# Defaults: AppStore-Release, .sisyphus/evidence/appstore-build.log
# The default (open-source) flavor is built with scheme BicTerm + Debug/Release
# instead — see README.md "Building".
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/env-local-caches.sh"

CONFIGURATION="${1:-AppStore-Release}"
case "$CONFIGURATION" in
    AppStore-Release|AppStore-Debug) ;;
    *)
        echo "error: AppStore builds must use AppStore-Release or AppStore-Debug, got '$CONFIGURATION'" >&2
        exit 2
        ;;
esac

LOG="${2:-$REPO_ROOT/.sisyphus/evidence/appstore-build.log}"
case "$LOG" in
    /*) ;;
    *)  LOG="$REPO_ROOT/$LOG" ;;
esac
mkdir -p "$(dirname "$LOG")"

CONFIG_LC="$(echo "$CONFIGURATION" | tr 'A-Z' 'a-z')"
DERIVED_DATA="$REPO_ROOT/.build-artifacts/DerivedData/appstore-$CONFIG_LC"

DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild build \
        -scheme BicTerm-AppStore \
        -configuration "$CONFIGURATION" \
        -destination "$DEST" \
        -derivedDataPath "$DERIVED_DATA" \
        -skipPackagePluginValidation -skipMacroValidation \
        2>&1 | tee "$LOG" | xcbeautify
    status=${PIPESTATUS[0]}
else
    xcodebuild build \
        -scheme BicTerm-AppStore \
        -configuration "$CONFIGURATION" \
        -destination "$DEST" \
        -derivedDataPath "$DERIVED_DATA" \
        -skipPackagePluginValidation -skipMacroValidation \
        2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
fi

if grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
    echo "check: '** BUILD SUCCEEDED **' present in $LOG"
    echo "app bundle: $DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/BicTerm.app"
else
    echo "check FAILED: '** BUILD SUCCEEDED **' not found in $LOG" >&2
    [ "$status" -eq 0 ] && status=1
fi
exit "$status"
