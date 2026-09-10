#!/bin/bash
set -euo pipefail
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
export PATH="$PWD/.build-artifacts/tools/bin:$PATH"
base="$PWD/Vendor/herdr"
pin=b99002ac99b09e00b4ca692436cb15a6b0d676f1
test "$(GIT_MASTER=1 git -C "$base/upstream" rev-parse HEAD)" = "$pin"
out="$base/herdr-client-core/src/client/endpoint"
mkdir -p "$out/activation" "$out/activation_cases" "$out/registry_cases"
extract() {
    local source="$1" ranges="$2" target="$3"
    {
        printf '// Derived from herdr %s %s (%s), Apache-2.0.\n' "$pin" "$source" "$ranges"
        printf '// Modified: public library visibility, transport-free state, Home instead of Local.\n'
        awk -v ranges="$ranges" -v source="$source" '
            BEGIN { n=split(ranges,p," "); for(i=1;i<=n;i++){split(p[i],b,":");lo[i]=b[1];hi[i]=b[2]} }
            { for(i=1;i<=n;i++) if(NR>=lo[i] && NR<=hi[i]) {
                if(source ~ /activation_tests/) {
                    if(NR==87 || NR==142 || NR==143 || (NR>=145 && NR<=150)) next;
                    if(NR==904 || NR==1042) { print "            endpoint,"; next; }
                    if(NR==946) { print "                endpoint_id: successor_endpoint,"; next; }
                    if(NR==906) { print "        }) if endpoint == test_source()"; next; }
                    if(NR==950) { print "        }) if successor_endpoint == test_source()"; next; }
                    if(NR==1043) { print "        }) if previous == disconnected && endpoint == test_source()"; next; }
                    if(NR==194) { print "            cells: vec![crate::protocol::CellData { symbol: String::new(), fg: 0, bg: 0, modifier: 0, skip: false, hyperlink: None }; 80 * 24],"; next; }
                    if(NR==188) sub(/^fn surface/,"pub(super) fn surface");
                    sub(/shell.set_snapshot\(/,"shell.set_endpoint_snapshot_for_generation(\\&test_source(), 1, ");
                    sub(/set_endpoint_snapshot\(&target,/,"set_endpoint_snapshot_for_generation(\\&target, 7,");
                }
                gsub(/pub\(crate\)/,"pub");
                if(source == "src/client/endpoint/activation.rs") sub(/^    fn /,"    pub(super) fn ");
                if(source ~ /registry.rs/ && NR==320) sub(/fn record_failure/,"pub(super) fn record_failure");
                if(source ~ /registry.rs/ && NR>=362) gsub(/super::super::/,"crate::client::endpoint::");
                gsub(/const MAX_CATALOG_BYTES: u64/,"const MAX_CATALOG_BYTES: usize");
                if(source ~ /activation_tests/ || (source ~ /registry.rs/ && NR>=362)) {
                    gsub(/ClientEndpointId::Local/,"test_source()");
                } else if(source ~ /registry.rs/ && NR>=101 && NR<=116) {
                    gsub(/ClientEndpointId::Local/,"super::test_source()");
                } else { gsub(/ClientEndpointId::Local/,"ClientEndpointId::Home"); }
                gsub(/    Local,/,"    Home,");
                gsub(/Self::Local/,"Self::Home");
                gsub(/is_local/,"is_home");
                gsub(/select_unavailable_local/,"select_unavailable_home");
                if(source ~ /registry.rs/ && NR==476) sub(/recovered_local_uses_transport_failure_not_remote_health_probes/,"recovered_source_is_remote_and_uses_health_probes");
                if(source ~ /registry.rs/ && NR==490) sub(/is_some/,"is_none");
                if(source ~ /registry.rs/ && NR==492) { print "        assert_eq!(registry.take_failures().len(), 1);"; next; }
                if(source ~ /registry.rs/ && NR==154) { print "    ) -> bool {\n        if endpoint_id.is_home() { return false; }"; next; }
                if(source ~ /registry.rs/ && NR==169) print "        true";
                if(source ~ /surface_patch.rs/) {
                    gsub(/self.pane_surface/,"self.surface");
                    gsub(/Applied\(Option<ClientComposedSurfacePatch>\)/,"Applied");
                }
                gsub(/select_local/,"select_home");
                gsub(/crate::remote::validate_remote_target/,"super::validation::validate_remote_target");
                gsub(/crate::session::validate_name/,"super::validation::validate_name");
                if(source ~ /registry.rs/ && NR==101) print "    #[cfg(test)]";
                print;
                if(source == "src/client/endpoint/activation/protocol.rs" && NR==81) print "    crate::surface::validate_surface(&surface)?;";
                if(source ~ /registry.rs/ && NR==107) print "        registry.active = super::test_source();";
                if(source ~ /activation_tests/ && NR==100) print "    assert!(shell.activate_endpoint_projection(&test_source()));";
                break
            }}' "$base/upstream/$source"
    } > "$target"
}
extract src/client/endpoint.rs '1:5 23:120' "$out/identity.rs"
extract src/client/endpoint/health.rs '1:99' "$out/health.rs"
extract src/client/endpoint/message_policy.rs '1:124' "$out/message_policy.rs"
extract src/client/endpoint/catalog.rs '1:1 6:10 12:15 18:82 91:101 160:274' "$out/catalog.rs"
printf '\n}\n' >> "$out/catalog.rs"
printf '\n#[path = "catalog_codec.rs"]\nmod codec;\n' >> "$out/catalog.rs"
extract src/remote/args.rs '118:126' "$out/validation.rs"
printf '\nconst MAX_SESSION_NAME_LEN: usize = 64;\n' >> "$out/validation.rs"
extract src/session.rs '425:446' "$out/session_validation.rs"
printf '\ninclude!("session_validation.rs");\n' >> "$out/validation.rs"
extract src/client/endpoint/registry.rs '1:146 241:266 347:360' "$out/registry.rs"
printf '\n#[path = "registry_connections.rs"]\nmod connections;\n#[path = "registry_transport.rs"]\nmod transport;\n' >> "$out/registry.rs"
for spec in 'connections 147:240' 'transport 267:346'; do
    set -- $spec
    extract src/client/endpoint/registry.rs "$2" "$out/registry_$1.rs"
    { printf '\n}\nuse super::*;\n'; } >> "$out/registry_$1.rs"
    # The range consists of complete methods; place them in a separate impl block.
    awk 'NR==3 {print "impl EndpointRegistry {"} {print}' "$out/registry_$1.rs" > "$out/registry_$1.rs.tmp"
    mv "$out/registry_$1.rs.tmp" "$out/registry_$1.rs"
done
printf '\n#[cfg(test)]\n#[path = "registry_tests.rs"]\nmod tests;\n' >> "$out/registry.rs"
extract src/client/endpoint/registry.rs '364:397' "$out/registry_tests.rs"
printf '\nuse super::super::test_source;\n' >> "$out/registry_tests.rs"
for spec in 'isolation 398:493' 'health 495:628'; do
    set -- $spec
    extract src/client/endpoint/registry.rs "$2" "$out/registry_cases/$1.rs"
    printf '\nuse super::*;\n' >> "$out/registry_cases/$1.rs"
    printf '\n#[path = "registry_cases/%s.rs"]\nmod %s;\n' "$1" "$1" >> "$out/registry_tests.rs"
done
extract src/client/endpoint/activation.rs '1:14 1150:1152' "$out/activation.rs"
for spec in 'begin 17:142' 'correlation 144:294' 'response 295:441' 'evidence 443:678' 'rollback 679:817' 'completion 818:920' 'commands 921:1147'; do
    set -- $spec
    extract src/client/endpoint/activation.rs "$2" "$out/activation/$1.rs"
    printf '\n}\nuse super::*;\n' >> "$out/activation/$1.rs"
    awk 'NR==3 {print "impl PendingEndpointActivation {"} {print}' "$out/activation/$1.rs" > "$out/activation/$1.rs.tmp"
    mv "$out/activation/$1.rs.tmp" "$out/activation/$1.rs"
    printf '\nmod %s;\n' "$1" >> "$out/activation.rs"
done
extract src/client/endpoint/activation/model.rs '1:174' "$out/activation/model.rs"
extract src/client/endpoint/activation/protocol.rs '1:219' "$out/activation/protocol.rs"
extract src/client/endpoint/activation_tests.rs '1:187 231:254' "$out/activation_tests.rs"
printf '\nuse super::super::test_source;\n' >> "$out/activation_tests.rs"
extract src/client/endpoint/activation_tests.rs '188:230' "$out/activation_cases/fixture_surface.rs"
printf '\nuse super::*;\n' >> "$out/activation_cases/fixture_surface.rs"
printf '\n#[path = "activation_cases/fixture_surface.rs"]\nmod fixture_surface;\nuse fixture_surface::surface;\n' >> "$out/activation_tests.rs"
for spec in 'begin 255:450' 'identity 451:643' 'rollback 644:815' 'successor 816:977' 'recovery 978:1139' 'failure 1140:1305'; do
    set -- $spec
    extract src/client/endpoint/activation_tests.rs "$2" "$out/activation_cases/$1.rs"
    printf '\nuse super::*;\n' >> "$out/activation_cases/$1.rs"
    printf '\n#[path = "activation_cases/%s.rs"]\nmod %s;\n' "$1" "$1" >> "$out/activation_tests.rs"
done
extract src/client/shell/surface_patch.rs '8:55 94:167' "$base/herdr-client-core/src/client/surface_patch.rs"
{
    printf '\n        let mut next = current.clone();\n'
    printf '        if !apply_patch_to_surface(&mut next, &patch) || crate::surface::validate_surface(&next).is_err() { return ClientPaneSurfacePatchOutcome::Rejected; }\n'
    printf '        self.surface = Some(next);\n        ClientPaneSurfacePatchOutcome::Applied\n    }\n}\n'
    printf 'use super::ClientShellState;\nuse crate::protocol::FrameData;\n'
} >> "$base/herdr-client-core/src/client/surface_patch.rs"
cargo fmt --manifest-path "$base/Cargo.toml" --all
