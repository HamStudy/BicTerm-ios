# Modification ledger

Baseline: `b99002ac99b09e00b4ca692436cb15a6b0d676f1` (v0.9.0).
Local owner: BicTerm task 13.

| Local path | Upstream path | Change | Reason |
| --- | --- | --- | --- |
| `LICENSE` | `LICENSE` | None; exact archived copy | Preserve upstream license |
| `.gitignore` | None | New local file | Keep reference checkout, source tar, and build output out of commits |
| `UPSTREAM_SOURCE.sha256` | Entire pinned tree | New archive digest record | Reproducible source provenance |
| `PROVENANCE.md` | None | New local record | Source/toolchain provenance and explicit incomplete audit status |
| `EXTRACTION_ESCALATION.md` | Referenced source locations | New boundary assessment | Preserve exact unresolved extraction work without publishing partial APIs |
| `UPSTREAM_PROPOSAL.md` | None | Unsubmitted discussion draft | Respect upstream contribution policy while recording the client-library use case |

The upstream checkout remains pristine. The protocol extraction below supersedes
the initial boundary probe; the old probe is not a shipping dependency.

## Protocol milestone

Every row below uses baseline `b99002ac99b09e00b4ca692436cb15a6b0d676f1`.
`extract-protocol.sh` is the repeatable extraction recipe. Line ranges are
inclusive in the pinned upstream source; generated headers retain provenance.
No serialized field, enum variant order, or bincode configuration was changed.

| Local path (under herdr-protocol) | Upstream file and lines | Change and reason |
| --- | --- | --- |
| `src/input.rs` | `src/protocol/wire.rs:19-190` | Keep input enums/constants; relocate WindowsKeyRecord; remove desktop conversion impls |
| `src/client.rs` | `wire.rs:465-631,652-694` | Complete frozen client message enum, host-theme and clipboard/scroll data; exclude terminal-theme conversions |
| `src/frame.rs` | `wire.rs:700-717,731-767` | Cell/frame/cursor data only; exclude ratatui buffer adapters |
| `src/snapshot.rs` | `wire.rs:886-970,996-1077` | Full snapshot projection and forward-compatible status parser; relocate AgentStatus; exclude config action conversions |
| `src/surface.rs` | `wire.rs:1078-1127,1138-1282` | Full geometry, graphics, surface, patch, popup and terminal frame data; exclude ratatui Rect conversion |
| `src/server.rs` | `wire.rs:1284-1449` | Complete frozen server enum and notification data; relocate ToastHerdrPosition; no server execution |
| `src/foundational.rs` | `src/input/model.rs:6-14`, `src/api/schema/common.rs:158-166`, `src/config/model.rs:71-81` | Copy WindowsKeyRecord, AgentStatus, ToastHerdrPosition exactly; remove schema-generation-only derives to avoid unrelated schema dependency |
| `src/framing.rs` | `wire.rs:1546-1712` | Preserve actual upstream framing and version checks; restore std::io imports; expose prefix constant crate-locally |
| `src/endpoint.rs`, `tests/upstream_endpoint.rs` | `src/protocol/endpoint.rs:1-138,140-319` | Split contract from tests; use package version for welcome construction instead of binary build_info; relocate shared paths |
| `src/lib.rs`, `Cargo.toml` | New | Public reexports and minimal serde/bincode dependencies, no desktop runtime |
| `tests/upstream_client.rs` | `wire.rs:1736-1980` | Port client round trips and frozen tags unchanged |
| `tests/upstream_messages.rs` | `wire.rs:2114-2327` | Port clipboard/focus/theme/request and remaining client round trips unchanged |
| `tests/upstream_surfaces.rs` | `wire.rs:2423-2610` | Port patch/graphics SHA256 golden assertions and server tags unchanged |
| `tests/upstream_server.rs` | `wire.rs:2612-2875` | Port snapshot, notification and remaining server round trips; relocate foundational paths |
| `tests/upstream_framing.rs` | `wire.rs:2876-2891,2951-3191,3471-3500` | Port framing/error/partial-read/version tests and original chunked reader |
| `tests/fixtures/endpoint-hello-v1.json` | Same path | Exact archived upstream fixture |
| `tests/fixtures/endpoint-welcome-v1.json` | Same path | Exact archived upstream fixture |
| `tests/fixtures/endpoint-snapshot-v1.json` | Same path | Exact archived upstream fixture |

Excluded tests exercise the deliberately excluded crossterm/ratatui/terminal-key
conversion implementations. Retained frozen digests were not regenerated.
Resolution sequence: initial extraction revealed two range-boundary errors,
then missing std::io imports and test-only digest/chunked-reader helpers;
correcting the recipe yielded 62 passing tests with no compiler warnings.
No missing runtime module was replaced by a no-op implementation.
