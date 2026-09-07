#!/bin/bash
set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SPIKE_ROOT/../.." && pwd)"
SCRATCH="$REPO_ROOT/.scratch/task-20"
ARTIFACTS="$REPO_ROOT/.build-artifacts/task-20"
EVIDENCE="$REPO_ROOT/.sisyphus/evidence/task-20-wireguardkit.log"
PENDING_EVIDENCE="$SCRATCH/task-20-wireguardkit.pending.log"
MODULE_CACHE="$ARTIFACTS/clang-module-cache-wireguard"
ATTEMPT_LOG="$SCRATCH/wireguardkit-compiler-attempt.log"
WG_PROBE_SOURCE="$SCRATCH/WireGuardKitImportProbe.swift"

mkdir -p "$SCRATCH/home" "$SCRATCH/tmp" "$ARTIFACTS" "$MODULE_CACHE" \
    "$REPO_ROOT/.sisyphus/evidence"

export HOME="$SCRATCH/home"
export CFFIXED_USER_HOME="$SCRATCH/home"
export TMPDIR="$SCRATCH/tmp"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE"

ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] || ARCH="x86_64"
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cp "$SPIKE_ROOT/WireGuardKitProbe/WireGuardKitImportProbe.swift.in" "$WG_PROBE_SOURCE"

perform_probe() {
    printf 'Task 20 WireGuardKit viability spike\n'
    printf 'containment: HOME=%s TMPDIR=%s artifacts=%s module_cache=%s\n' "$HOME" "$TMPDIR" "$ARTIFACTS" "$MODULE_CACHE"
    printf 'sdk=%s target=%s-apple-ios18.0-simulator\n' "$SDK_PATH" "$ARCH"

    printf '%s\n' '$ xcrun swiftc PacketTunnelProviderProbe.swift -emit-library -framework NetworkExtension'
    set +e
    xcrun swiftc \
        -parse-as-library \
        -emit-library \
        -target "$ARCH-apple-ios18.0-simulator" \
        -sdk "$SDK_PATH" \
        -framework NetworkExtension \
        -module-cache-path "$MODULE_CACHE" \
        "$SPIKE_ROOT/WireGuardKitProbe/PacketTunnelProviderProbe.swift" \
        -o "$ARTIFACTS/PacketTunnelProviderProbe.dylib"
    NE_STATUS=$?
    set -e
    printf 'networkextension_compile_link_exit_code=%d\n' "$NE_STATUS"
    if [[ "$NE_STATUS" -ne 0 ]]; then
        printf 'TASK 20 WIREGUARDKIT RESULT: FAILED before WireGuardKit probe\n'
        return "$NE_STATUS"
    fi
    BUILD_METADATA="$(xcrun vtool -show-build "$ARTIFACTS/PacketTunnelProviderProbe.dylib")"
    printf '%s\n' "$BUILD_METADATA"
    if ! grep -Fq "platform IOSSIMULATOR" <<< "$BUILD_METADATA"; then
        printf 'TASK 20 WIREGUARDKIT RESULT: linked output is not an iOS Simulator binary\n'
        return 1
    fi
    printf 'networkextension_platform_check=IOSSIMULATOR\n'

    printf '%s\n' '$ xcrun swiftc WireGuardKitImportProbe.swift -o WireGuardKitImportProbe'
    WG_ARGS=(
        -parse-as-library
        -target "$ARCH-apple-ios18.0-simulator"
        -sdk "$SDK_PATH"
        -module-cache-path "$MODULE_CACHE"
    )
    if [[ -n "${WIREGUARDKIT_SEARCH_PATH:-}" ]]; then
        if [[ ! -d "$WIREGUARDKIT_SEARCH_PATH" ]]; then
            printf 'FAILED: WIREGUARDKIT_SEARCH_PATH must be an existing directory\n'
            return 1
        fi
        CANONICAL_WIREGUARDKIT_SEARCH_PATH="$(cd "$WIREGUARDKIT_SEARCH_PATH" && pwd -P)"
        case "$CANONICAL_WIREGUARDKIT_SEARCH_PATH" in
            "$REPO_ROOT"|"$REPO_ROOT"/*) ;;
            *) printf 'FAILED: WIREGUARDKIT_SEARCH_PATH must resolve inside %s\n' "$REPO_ROOT"; return 1 ;;
        esac
        WG_ARGS+=(-I "$CANONICAL_WIREGUARDKIT_SEARCH_PATH" -L "$CANONICAL_WIREGUARDKIT_SEARCH_PATH" -lWireGuardKit)
    fi
    set +e
    xcrun swiftc "${WG_ARGS[@]}" \
        "$WG_PROBE_SOURCE" \
        -o "$ARTIFACTS/WireGuardKitImportProbe" \
        > "$ATTEMPT_LOG" 2>&1
    WG_STATUS=$?
    set -e
    cat "$ATTEMPT_LOG"
    printf 'wireguardkit_compile_link_exit_code=%d\n' "$WG_STATUS"

    if [[ "$WG_STATUS" -eq 0 ]]; then
        printf 'WireGuardKit import and symbol link: AVAILABLE via project-local inputs\n'
    elif grep -Fq "no such module 'WireGuardKit'" "$ATTEMPT_LOG"; then
        printf 'WireGuardKit import and symbol link: UNAVAILABLE (module is not present locally)\n'
        printf 'No package fetch was attempted because package-manager/network writes cannot be guaranteed project-local.\n'
    else
        printf 'TASK 20 WIREGUARDKIT RESULT: unexpected compiler failure\n'
        return "$WG_STATUS"
    fi
    printf 'WireGuardKit protocol scope: ordinary WireGuard only; no Coder coordination, DERP, DISCO, magicsock, NAT traversal, or peer authorization.\n'
    printf 'TASK 20 WIREGUARDKIT RESULT: PROBE COMPLETE\n'
}

: > "$PENDING_EVIDENCE"
set +e
perform_probe > "$PENDING_EVIDENCE" 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
    mv "$PENDING_EVIDENCE" "$EVIDENCE"
    cat "$EVIDENCE"
else
    cat "$PENDING_EVIDENCE" >&2
fi
exit "$status"
