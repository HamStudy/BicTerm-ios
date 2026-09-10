# herdr-fixture-gen

Deterministic UI-test fixtures for the Herdr workspace (T16), produced
through the REAL extracted v0.9.0 codec (`herdr_protocol::write_message`) —
never hand-authored bytes. The crate depends on `Vendor/herdr` read-only.

Regenerate (outputs are committed under `Fixtures/herdr/golden/`):

```sh
source scripts/env-local-caches.sh
export RUSTUP_HOME="$PWD/.build-artifacts/rustup"
cargo run --manifest-path Fixtures/herdr/gen/Cargo.toml -- --out Fixtures/herdr/golden
```

Outputs:

| file | content |
| ---- | ------- |
| `welcome-gen99.bin` | `endpoint.welcome.v1` control with generation 99 — drives the version-mismatch diagnostic |
| `snapshot-2x2.bin` | `shell.snapshot.v1` carrier: 1 workspace, 1 tab, 4 panes (`w1:p1`..`w1:p4`), focus on `w1:p2`, boot `boot-2x2` revision 1 |
| `surface-2x2.bin` | `ServerMessage::PaneSurface` matching that snapshot identity (80x24 frame, 2x2 pane rects, splits, cursor) |
| `surface-2x2.json` | serde JSON of the same `PaneSurfaceFrame` — byte-shape-identical to what `herdr_client_surface` returns once a surface commits (see `.sisyphus/evidence/phase2-h16-ffi-surface-probe.log` for why the committed FFI cannot commit one yet) |

Probe (blocker evidence, no writes):

```sh
cargo run --manifest-path Fixtures/herdr/gen/Cargo.toml -- \
  --probe --golden Vendor/herdr/herdr-protocol/tests/fixtures/golden
```
