#!/bin/bash
# herdr-server-fetch.sh — fetch the pinned prebuilt herdr server binary
# (standing project policy: NEVER build the herdr server from source/zig).
#
# Downloads the herdr v0.9.1 macOS aarch64 release asset into
# Fixtures/run/herdr/herdr (gitignored) and verifies it against the committed
# sha256 lockfile Fixtures/herdr/server-0.9.1.sha256. Idempotent: when the
# on-disk binary already matches the lockfile, nothing is downloaded.
#
# Asset: https://github.com/herdrdev/herdr/releases/download/v0.9.1/herdr-macos-aarch64
# (asset name verified against the v0.9.1 release page with curl)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/Fixtures/run/herdr"
BIN="$RUN/herdr"
LOCK="$ROOT/Fixtures/herdr/server-0.9.1.sha256"
URL="https://github.com/herdrdev/herdr/releases/download/v0.9.1/herdr-macos-aarch64"

expected="$(awk 'NR==1 {print $1}' "$LOCK")"
if [ ${#expected} -ne 64 ]; then
  echo "FAIL: malformed lockfile $LOCK" >&2
  exit 1
fi

if [ -f "$BIN" ]; then
  actual="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  if [ "$actual" = "$expected" ]; then
    echo "herdr-server-fetch: $BIN already matches server-0.9.1.sha256 (skip)"
    exit 0
  fi
  echo "herdr-server-fetch: $BIN sha mismatch (or corrupted); re-downloading"
fi

mkdir -p "$RUN"
partial="$BIN.download"
# curl does not set com.apple.quarantine by default (only with --xattr); the
# explicit strip below is a belt-and-suspenders fallback for wrapper configs.
curl -fSL --no-xattr -o "$partial" "$URL"
chmod +x "$partial"
xattr -d com.apple.quarantine "$partial" 2>/dev/null || true

actual="$(shasum -a 256 "$partial" | awk '{print $1}')"
if [ "$actual" != "$expected" ]; then
  rm -f "$partial"
  echo "FAIL: downloaded herdr sha $actual != lockfile $expected" >&2
  exit 1
fi
mv "$partial" "$BIN"
echo "herdr-server-fetch: fetched herdr 0.9.1 -> $BIN (sha ok)"
