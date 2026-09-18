# Herdr source and build provenance

This directory contains `herdr-protocol` and the transport-neutral
`herdr-client-core` workspace extracted for task 13. The original desktop
renderer and interaction UI are not included. See `EXTRACTION_ESCALATION.md`
for the resolved boundaries and caller responsibilities. This is engineering
provenance, not legal approval or an App Store release certification.

## Upstream source

- Repository: https://github.com/herdrdev/herdr
- Release: v0.9.1 (multi-machine)
- Verified commit: `065ef9d6a531c49fb8bee7e818ef837065b21ee9`
- Unmodified reference checkout: `Vendor/herdr/upstream/` (ignored)
- Source archive: `Vendor/herdr/UPSTREAM_SOURCE.tar` (ignored)
- SHA256: `050b31ce77072c7ddf98e8f43cd261f531ff4fec3d4a0da9adcf9e1f50c56aa7`
- Hash record: `Vendor/herdr/UPSTREAM_SOURCE.sha256`
- Vendored license: [LICENSE](LICENSE), byte-for-byte upstream Apache-2.0 text.

The extracted crates below (`herdr-protocol`, `herdr-client-core`) were taken
from v0.9.0 (`b99002ac99b09e00b4ca692436cb15a6b0d676f1`) and have not been
re-extracted; `extract-protocol.sh` and `extract-client-core.sh` still verify
that pin. The reference checkout and source archive track v0.9.1, the embed
stack baseline (`MODIFICATIONS.md`, `EMBED-PATCHES.md`). Wire compatibility is
preserved: PROTOCOL_VERSION 22 and ENDPOINT_PROTOCOL_GENERATION 1 are
unchanged between the two releases.

Commands run from the BicTerm repository root:

```sh
source scripts/env-local-caches.sh
GIT_MASTER=1 git clone https://github.com/herdrdev/herdr Vendor/herdr/upstream
GIT_MASTER=1 git -C Vendor/herdr/upstream checkout 065ef9d6a531c49fb8bee7e818ef837065b21ee9
GIT_MASTER=1 git -C Vendor/herdr/upstream rev-parse HEAD
GIT_MASTER=1 git -C Vendor/herdr/upstream archive --format=tar HEAD \
  -o "$PWD/Vendor/herdr/UPSTREAM_SOURCE.tar"
shasum -a 256 Vendor/herdr/UPSTREAM_SOURCE.tar | tee Vendor/herdr/UPSTREAM_SOURCE.sha256
GIT_MASTER=1 git -C Vendor/herdr/upstream archive HEAD LICENSE | tar -x -C Vendor/herdr
```

The archive output uses an absolute repository-local path because `git -C`
changes where a relative output path resolves. The full upstream archive
includes excluded vendors for provenance only; it must never become an app
resource or a Cargo dependency.

## Toolchain provisioning (2026-09-09)

```sh
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
mkdir -p "$RUSTUP_HOME"
rustup toolchain install stable --profile minimal --no-self-update
rustup target add --toolchain stable aarch64-apple-ios aarch64-apple-ios-sim
rustup target list --installed --toolchain stable
rustc +stable --version
cargo +stable --version
cargo +stable install --locked --root "$PWD/.build-artifacts/tools" cargo-deny
rustup component add rustfmt --toolchain stable
"$PWD/.build-artifacts/tools/bin/cargo-deny" --version
```

Observed versions:

```text
rustc 1.98.1 (48a229cea 2026-09-01)
cargo 1.98.1 (797e8a9bc 2026-08-05)
cargo-deny 0.20.2
```

Installed targets: `aarch64-apple-darwin`, `aarch64-apple-ios`, and
`aarch64-apple-ios-sim`. Stable resolved to 1.98.1 on this date; reproductions
should select that version rather than assume the moving stable channel is
unchanged. The installed cargo-deny build used its published lockfile.

All controllable toolchain, Cargo registry, target, temporary, and installation
outputs were redirected under BicTerm. `.build-artifacts/` is already ignored.
The existing cache script does **not** set `RUSTUP_HOME`; repeat the explicit
export in every Rust shell. No external toolchain installation was performed.

## Notice scan

`git ls-files '*NOTICE*' '*LICENSE*'` found:

```text
LICENSE
packaging/windows/licenses/Microsoft.Windows.Console.ConPTY-LICENSE.txt
packaging/windows/licenses/Microsoft.Windows.Console.ConPTY-NOTICE.md
vendor/libghostty-vt/LICENSE
vendor/libghostty-vt/pkg/afl++/LICENSE
vendor/portable-pty/LICENSE.md
```

No root NOTICE exists at this pin. A case-insensitive source scan for
`copyright|SPDX-License-Identifier|licensed under` found no matches in
`src/protocol`, `src/client/endpoint.rs`, `src/client/endpoint`,
`src/client/shell.rs`, `src/client/shell`, or `src/client/shell_runtime.rs`.
The additional foundational sources (`input/model.rs`, `api/schema/common.rs`,
`config/model.rs`, `remote/args.rs`, `session.rs`) are covered by the final
source-notice scan. Copied files retain their upstream comments and carry
modification/provenance headers. No root NOTICE exists; the nested ConPTY
notice belongs to excluded Windows packaging, and no Ghostty/portable-pty
code or asset is copied into either crate. The complete archived source is
reference material only, never app input.

## Cargo-deny and target inventory

`bash Vendor/herdr/check.sh` resolves each iOS target independently with the
workspace's production/default features and excludes dev dependencies in
cargo-deny. There are no optional workspace features. `LICENSE_INVENTORY.json`
joins each target's actual cargo-deny package graph to Cargo metadata to retain
the exact license expressions, rather than treating all of Cargo.lock as a
shipping inventory. Each target contains 25 packages: two local crates and
23 external dependencies, including build-time proc macros.

The complete SPDX allowlist is Apache-2.0, MIT, Unicode-3.0, and Unlicense.
In particular, unicode-ident requires `(MIT OR Apache-2.0) AND Unicode-3.0`;
memchr declares `Unlicense OR MIT`. version_check's legacy `MIT/Apache-2.0`
expression is interpreted by cargo-deny. License texts and notices must be
carried into the eventual application acknowledgement bundle; this inventory
does not itself constitute that bundle.

Audit result: **licenses, bans, sources, and advisories pass under the checked-in
policy**, with one explicit maintenance exception:

- **RUSTSEC-2025-0141 — bincode is unmaintained.** There is no safe upgrade.
  Herdr generation 1 requires bincode 2.0.1; the dependency is pinned exactly
  and its real encode path is protected by upstream digests plus 43 committed
  frames. The exception acknowledges maintenance risk, not a vulnerability
  fix. BicTerm owns monitoring and future codec migration. It must be reviewed
  before release; it is not a blanket advisory exemption.
- No vulnerability, source, unknown-license, or unlicensed-package exemption.
  Negative checks remove a package's license or inject an unknown LicenseRef
  into resolved metadata and verify cargo-deny rejects both.
- Bans reject portable-pty, crossterm, ratatui, interprocess, wildcard dependency
  requirements, and duplicate package versions. The local path dependency has
  an exact `=0.9.0` version constraint.

## Verification and reproducibility

From the BicTerm root:

```sh
bash Vendor/herdr/extract-protocol.sh
bash Vendor/herdr/extract-client-core.sh
bash Vendor/herdr/check.sh
```

The extraction recipes verify the upstream commit and preserve declarations
by pinned source ranges; `MODIFICATIONS.md` records every mapping and adapter.
Both recipes run rustfmt and leave the upstream checkout untouched.

- Host tests: 65 protocol + 57 client-core = **122 passed**, no ignored tests.
- Build targets: `aarch64-apple-darwin`, `aarch64-apple-ios`,
  `aarch64-apple-ios-sim`.
- Golden frames: 21 client variants, 21 server variants, one additional stable
  JSON snapshot carrier; byte-exact encode and lossless decode checks.
- Exclusion audit: zero excluded runtime imports or process-spawning references
  in either crate source tree; dependency bans provide a second check.
- LSP diagnostics were attempted but the daemon timed out. Cargo build/tests
  and rustfmt are the completed verification gates; no clean LSP result is claimed.

Logs and per-target metadata are retained under `.sisyphus/evidence/phase2-h13-*`.
`UPSTREAM_PROPOSAL.md` is an unsubmitted Discussion draft, not a submitted issue
or PR. Native transport execution, rendering, C ABI/XCFramework, physical-device
QA, fuzzing, and App Store acknowledgement packaging are not task-13 artifacts.
