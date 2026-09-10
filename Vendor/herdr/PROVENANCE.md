# Herdr source provenance — extraction INCOMPLETE

This directory records the source baseline and toolchain for task 13. It is
**not a usable Cargo workspace or an approved distribution inventory**.

## Upstream source

- Repository: https://github.com/herdrdev/herdr
- Release: v0.9.0 (multi-machine)
- Verified commit: `b99002ac99b09e00b4ca692436cb15a6b0d676f1`
- Unmodified reference checkout: `Vendor/herdr/upstream/` (ignored)
- Source archive: `Vendor/herdr/UPSTREAM_SOURCE.tar` (ignored)
- SHA256: `6026052a4e11914fa7bc1d4080f44130dfa2640b02851029f6712613e6062beb`
- Hash record: `Vendor/herdr/UPSTREAM_SOURCE.sha256`
- Vendored license: [LICENSE](LICENSE), byte-for-byte upstream Apache-2.0 text.

Commands run from the BicTerm repository root:

```sh
source scripts/env-local-caches.sh
GIT_MASTER=1 git clone https://github.com/herdrdev/herdr Vendor/herdr/upstream
GIT_MASTER=1 git -C Vendor/herdr/upstream checkout b99002ac99b09e00b4ca692436cb15a6b0d676f1
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

## Preliminary notice scan

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
This is a preliminary source-header scan, not a substitute for reviewing all
files actually selected for extraction and their transitive dependencies.
The nested ConPTY notice and vendor licenses cannot be treated as absent.

## Cargo-deny and target inventory

**NOT RUN against a production graph.** cargo-deny is installed, but no
production workspace, feature set, or target-resolved dependency graph has
been completed. There is deliberately no guessed SPDX allowlist or passing
license claim. The diagnostic probe's dependency graph is not the shipping
graph. Unknown/unlicensed packages must fail the eventual production audit.

See [EXTRACTION_ESCALATION.md](EXTRACTION_ESCALATION.md) for exact boundaries,
verification limitations, and remaining work. No downstream API is ready.
