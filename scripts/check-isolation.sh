#!/bin/bash
# check-isolation.sh — enforces the BicTermCore module-isolation invariant:
# no SwiftUI/UIKit imports anywhere in BicTermCore/Sources/.
# Exit 1 (with file:line) on any violation, exit 0 when clean.
cd "$(dirname "$0")/.."

matches="$(grep -rnE '^[[:space:]]*import[[:space:]]+(SwiftUI|UIKit)\b' BicTermCore/Sources/ || true)"
if [ -n "$matches" ]; then
    echo "ISOLATION VIOLATION: UI framework import inside BicTermCore:"
    echo "$matches"
    exit 1
fi
echo "OK: BicTermCore/Sources has no SwiftUI/UIKit imports"
exit 0
