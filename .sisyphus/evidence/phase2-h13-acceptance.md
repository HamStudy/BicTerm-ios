# T13 verification — protocol and transport-neutral core

Verdict: PASS for the extracted protocol/pure-state boundary described in
`Vendor/herdr/README.md`. No structural-impossibility escalation. No native UI,
C ABI/XCFramework, physical-device validation, or task 14–16 implementation is
claimed by this lane.

## Delivered

- Pinned upstream v0.9.0 at b99002ac99b09e00b4ca692436cb15a6b0d676f1,
  pristine checkout and archived SHA256 6026052a4e11914fa7bc1d4080f44130dfa2640b02851029f6712613e6062beb.
- Workspace: herdr-protocol and herdr-client-core; no desktop runtime dependencies.
- 43 framed binary fixtures covering every frozen outer message variant plus
  the stable JSON snapshot carrier; unchanged upstream digest/tag assertions.
- Endpoint catalog, independent supervisors/health, generation-qualified state,
  coherent surface/patch handling, semantic pane input, and every activation
  phase through rollback/successor/presentation-ready fencing.
- Provenance, complete modification mappings, target-resolved license inventory,
  deny.toml, repeatable extraction scripts, and check.sh.

## Exact verification

From repository root, each shell used:

```sh
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
export PATH="$PWD/.build-artifacts/tools/bin:$PATH"
```

Commands/results:

```sh
cargo test --locked --manifest-path Vendor/herdr/Cargo.toml -p herdr-protocol -p herdr-client-core
# 65 protocol + 57 core = 122 passed; zero failed/ignored.
cargo build --locked --manifest-path Vendor/herdr/Cargo.toml --target aarch64-apple-darwin
cargo build --locked --manifest-path Vendor/herdr/Cargo.toml --target aarch64-apple-ios
cargo build --locked --manifest-path Vendor/herdr/Cargo.toml --target aarch64-apple-ios-sim
# All three passed.
cargo-deny --manifest-path Vendor/herdr/Cargo.toml --config Vendor/herdr/deny.toml --exclude-dev --locked check
# advisories ok, bans ok, licenses ok, sources ok — see exception below.
bash Vendor/herdr/extract-protocol.sh
bash Vendor/herdr/extract-client-core.sh
GIT_MASTER=1 git diff --exit-code -- Vendor/herdr/herdr-protocol Vendor/herdr/herdr-client-core
# Regeneration left committed crate files unchanged.
bash Vendor/herdr/check.sh
# Full gate passed. Unknown/unlicensed metadata rejected in negative checks.
```

Evidence: `phase2-h13-final-check.log`, `phase2-h13-tests.log`,
`phase2-h13-build-*.log`, `phase2-h13-golden.log`,
`phase2-h13-cargo-deny.log`, `phase2-h13-{unknown,unlicensed}-rejection.log`,
`phase2-h13-exclusion-audit.log`, `phase2-h13-source-sizes.log`.

Each target's production graph has 25 packages, including build dependencies.
SPDX allowlist: Apache-2.0, MIT, Unicode-3.0, Unlicense. Expressions and versions
are in `Vendor/herdr/LICENSE_INVENTORY.json`; raw metadata/graphs are retained
in `phase2-h13-metadata-*` and `phase2-h13-license-graph-*`.

The source exclusion scan returned zero excluded runtime/process imports.
The final selected-source notice scan returned no additional file-level
copyright/SPDX/license notices. Root LICENSE was preserved; the only discovered
nested NOTICE belongs to excluded ConPTY packaging.

## Exceptions and boundaries

- RUSTSEC-2025-0141 reports bincode unmaintained with no safe upgrade. The policy
  has one explicit maintenance exception for the exactly pinned generation-1
  codec. No vulnerability or unknown/unlicensed exception was added. This
  maintenance risk remains open for release review.
- LSP diagnostics were requested for both crate trees but the daemon timed out.
  Cargo and rustfmt are the completed gates; LSP is not reported green.
- Rendering, native gestures/selection/keymaps, presentation replay execution,
  SSH I/O, response-chunk assembly, aggregate budgets and per-viewer scheduling
  remain caller responsibilities, not stubbed desktop services.
- Upstream proposal: [tracked unsubmitted draft](../../Vendor/herdr/UPSTREAM_PROPOSAL.md).
  Intended venue: https://github.com/herdrdev/herdr/discussions. No submitted
  issue/PR URL or upstream approval exists; contribution policy forbids an
  unsolicited feature-request issue from an external agent.
- Plan/protected files and T15's Swift/fixture work were not modified or staged.
