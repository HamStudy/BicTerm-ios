#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env-local-caches.sh
export HOME="$ROOT/.build-artifacts/Home"
export XDG_CACHE_HOME="$HOME/.cache"
BUILD="$ROOT/.build-artifacts/coder-g12-host"
mkdir -p "$BUILD" "$ROOT/Fixtures/run/g12s"
CGO_ENABLED=1 go -C CoderNet build -buildmode=c-archive -o "$BUILD/CoderNet.a" .
clang -Wall -Wextra -Werror -I "$BUILD" Fixtures/coder/raw-adapter.c \
    "$BUILD/CoderNet.a" -framework CoreFoundation -framework Security \
    -framework Foundation -lresolv -o "$BUILD/raw-adapter"
ruby scripts/test-coder-raw.rb
