#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env-local-caches.sh"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT="$ROOT/.build-artifacts/coder-net"
mkdir -p "$OUT/device/include" "$OUT/simulator/include"
cd "$ROOT/CoderNet"

# Device slice
CC=$(xcrun --sdk iphoneos --find clang) \
GOOS=ios GOARCH=arm64 \
CGO_ENABLED=1 \
CGO_CFLAGS="-isysroot $IOS_SDK -arch arm64 -miphoneos-version-min=18.0" \
CGO_LDFLAGS="-isysroot $IOS_SDK -arch arm64 -miphoneos-version-min=18.0" \
go build -buildmode=c-archive -o "$OUT/device/CoderNet.a" .

# c-archive emits its header next to the archive; xcframework wants a headers dir.
cp "$OUT/device/CoderNet.h" "$OUT/device/include/"

# Simulator slice
CC=$(xcrun --sdk iphonesimulator --find clang) \
GOOS=ios GOARCH=arm64 \
CGO_ENABLED=1 \
CGO_CFLAGS="-isysroot $SIM_SDK -arch arm64 -mios-simulator-version-min=18.0" \
CGO_LDFLAGS="-isysroot $SIM_SDK -arch arm64 -mios-simulator-version-min=18.0" \
go build -buildmode=c-archive -o "$OUT/simulator/CoderNet.a" .

cp "$OUT/simulator/CoderNet.h" "$OUT/simulator/include/"

# Assemble XCFramework
xcodebuild -create-xcframework \
  -library "$OUT/device/CoderNet.a" -headers "$OUT/device/include" \
  -library "$OUT/simulator/CoderNet.a" -headers "$OUT/simulator/include" \
  -output "$OUT/CoderNet.xcframework"

echo "BUILD SUCCESS: CoderNet.xcframework created"
