#!/bin/bash
set -euo pipefail
root="$(pwd)"
source scripts/env-local-caches.sh
export RUSTUP_HOME="$root/.build-artifacts/rustup"
export PATH="$root/.build-artifacts/tools/bin:$PATH"
base="$root/Vendor/herdr"
pin=b99002ac99b09e00b4ca692436cb15a6b0d676f1
test "$(GIT_MASTER=1 git -C "$base/upstream" rev-parse HEAD)" = "$pin"
test -z "$(GIT_MASTER=1 git -C "$base/upstream" status --porcelain)"
mkdir -p "$base/herdr-protocol/src" "$base/herdr-protocol/tests/fixtures"

# Pinned line ranges preserve frozen declarations; only paths and schema-only derives change.
extract() {
    local source="$1" ranges="$2" destination="$3"
    {
        printf '// Derived from herdr %s %s (%s). Apache-2.0.\n' "$pin" "$source" "$ranges"
        printf '// Modified: desktop conversions excluded; shared data paths relocated.\n'
        if [[ "$destination" == tests/* ]]; then
            printf 'use herdr_protocol::*;\n'
            case "$destination" in
                tests/upstream_endpoint.rs) printf 'use herdr_protocol::endpoint::*;\n' ;;
                tests/upstream_framing.rs|tests/upstream_snapshot.rs) ;;
                *) printf 'use serde::Serialize;\n' ;;
            esac
        elif [[ "$destination" != */endpoint.rs ]]; then
            printf 'use serde::{Deserialize, Serialize};\n'
            case "$destination" in
                src/client.rs|src/surface.rs|src/server.rs|src/framing.rs) printf 'use super::*;\n' ;;
            esac
        fi
        case "$destination" in
            src/framing.rs) printf 'use std::io::{self, Read, Write};\n' ;;
            tests/upstream_framing.rs) printf 'use std::io::{self, Read};\n' ;;
        esac
        awk -v ranges="$ranges" '
            BEGIN { n=split(ranges, parts, " "); for(i=1;i<=n;i++) { split(parts[i], pair, ":"); first[i]=pair[1]; last[i]=pair[2] } }
            { for(i=1;i<=n;i++) if(NR>=first[i] && NR<=last[i]) {
                gsub(/crate::input::WindowsKeyRecord/, "crate::WindowsKeyRecord");
                gsub(/crate::api::schema::AgentStatus/, "crate::AgentStatus");
                gsub(/crate::config::ToastHerdrPosition/, "crate::ToastHerdrPosition");
                gsub(/crate::protocol::ClientShellCommandAction/, "crate::ClientShellCommandAction");
                gsub(/crate::build_info::version\(\)/, "env!(\"CARGO_PKG_VERSION\").to_owned()");
                gsub(/, schemars::JsonSchema/, "");
                gsub(/const LENGTH_PREFIX_BYTES/, "pub(crate) const LENGTH_PREFIX_BYTES");
                print; break
            }}' "$base/upstream/$source"
    } > "$base/herdr-protocol/$destination"
}

wire=src/protocol/wire.rs
extract "$wire" '19:190' src/input.rs
extract "$wire" '465:631 652:694' src/client.rs
extract "$wire" '700:717 731:767' src/frame.rs
extract "$wire" '886:970 996:1077' src/snapshot.rs
extract "$wire" '1078:1127 1138:1282' src/surface.rs
extract "$wire" '1284:1449' src/server.rs
extract "$wire" '1546:1712' src/framing.rs
extract src/protocol/endpoint.rs '1:138' src/endpoint.rs
extract src/protocol/endpoint.rs '140:319' tests/upstream_endpoint.rs
extract src/input/model.rs '6:14' src/foundational.rs
awk 'NR>=158 && NR<=166 { gsub(/, schemars::JsonSchema/, ""); print }' "$base/upstream/src/api/schema/common.rs" >> "$base/herdr-protocol/src/foundational.rs"
awk 'NR>=71 && NR<=81 { gsub(/schemars::JsonSchema, /, ""); print }' "$base/upstream/src/config/model.rs" >> "$base/herdr-protocol/src/foundational.rs"

extract "$wire" '1736:1980' tests/upstream_client.rs
extract "$wire" '2114:2327' tests/upstream_messages.rs
extract "$wire" '2423:2610' tests/upstream_surfaces.rs
extract "$wire" '2612:2693' tests/upstream_snapshot.rs
extract "$wire" '2695:2875' tests/upstream_server.rs
extract "$wire" '2876:2891 2951:3191 3471:3500' tests/upstream_framing.rs
for file in upstream_client upstream_messages upstream_surfaces upstream_server; do
    printf '\nfn encoded_sha256(value: &impl Serialize) -> String { use sha2::{Digest, Sha256}; format!("{:x}", Sha256::digest(bincode::serde::encode_to_vec(value, bincode::config::standard()).unwrap())) }\n' >> "$base/herdr-protocol/tests/$file.rs"
done
GIT_MASTER=1 git -C "$base/upstream" archive HEAD tests/fixtures/endpoint-hello-v1.json tests/fixtures/endpoint-welcome-v1.json tests/fixtures/endpoint-snapshot-v1.json | tar -x -C "$base/herdr-protocol"
cargo fmt --manifest-path "$base/Cargo.toml" --all
