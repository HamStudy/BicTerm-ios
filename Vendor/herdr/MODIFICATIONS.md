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

## Client-core milestone

All upstream references below use the same full baseline commit above. Local
paths are under `herdr-client-core/`; endpoint paths abbreviate
`src/client/endpoint/`. The recipe is `extract-client-core.sh`. The extraction
widens crate-private public APIs, retains model-field encapsulation, and splits
impls by transition responsibility rather than changing transition logic.

| Local file | Upstream source / change | Reason |
| --- | --- | --- |
| `src/lib.rs`, `src/client.rs`, `src/client/endpoint.rs`, `Cargo.toml` | New library roots, reexports, dependency declarations | Public transport-neutral API; forbid unsafe code |
| `endpoint/identity.rs` | `src/client/endpoint.rs:1-5,23-120`; Local -> Home | Preserve opaque profile identity; neutral home has no local server |
| `endpoint/catalog.rs` | `catalog.rs:1,6-10,12-15,18-82,91-101,160-274` | Retain validation and catalog mutations; exclude filesystem discovery and persistence |
| `endpoint/catalog_codec.rs` | Adapt `catalog.rs:276-303` to supplied byte buffers | Bound and validate imported catalog without reading desktop config paths |
| `endpoint/validation.rs` | `src/remote/args.rs:118-126` | Pure target validation only; no SSH process/preparation code |
| `endpoint/session_validation.rs` | `src/session.rs:425-446`, limit from line 13 | Preserve session grammar without process environment/discovery |
| `endpoint/health.rs` | `health.rs:1-99` | Independent initial-snapshot and heartbeat deadlines, including upstream tests |
| `endpoint/message_policy.rs` | `message_policy.rs:1-124` | Preserve inactive metadata/presentation separation and tests |
| `endpoint/registry.rs` | `registry.rs:1-146,241-266,347-360` | Lifecycle root; default to Home, desktop constructor test-only |
| `endpoint/registry_connections.rs` | `registry.rs:147-240` | Insert/generation/health behavior; reject a transport for Home |
| `endpoint/registry_transport.rs` | `registry.rs:267-346` | Per-endpoint sends, disconnects and failure isolation |
| `endpoint/registry_tests.rs` | `registry.rs:364-397` | Shared upstream transport fixtures; Local replaced with an actual SSH source profile |
| `endpoint/registry_cases/isolation.rs` | `registry.rs:398-493` | Isolation/recovery tests; recovered source now correctly requires remote health |
| `endpoint/registry_cases/health.rs` | `registry.rs:495-628` | Health, admission, stale-generation and drop tests |
| `endpoint/activation.rs` | `activation.rs:1-14,1150-1152` | State-machine root and exports |
| `endpoint/activation/begin.rs` | `activation.rs:17-142` | Preflight and source-off-first start |
| `endpoint/activation/correlation.rs` | `activation.rs:144-294` | Lease/response matching, supersession and timeouts |
| `endpoint/activation/response.rs` | `activation.rs:295-441` | Typed acknowledgment transitions |
| `endpoint/activation/evidence.rs` | `activation.rs:443-678` | Snapshot/surface evidence, resize/focus/theme restart |
| `endpoint/activation/rollback.rs` | `activation.rs:679-817` | Disconnect handling and acknowledged rollback |
| `endpoint/activation/completion.rs` | `activation.rs:818-920` | Atomic selection and post-commit synchronization |
| `endpoint/activation/commands.rs` | `activation.rs:921-1147` | Target/source activation writes, presentation fence and coherence progress |
| `endpoint/activation/model.rs` | `activation/model.rs:1-174` | Preserve all phases, evidence and successor state |
| `endpoint/activation/protocol.rs` | `activation/protocol.rs:1-219` | Preserve request shapes/correlation; additionally validate a completed surface before commit |
| `endpoint/activation_tests.rs` | `activation_tests.rs:1-187,231-254` | Adapt fixtures to neutral state and explicit source/target generations; no UI config stub |
| `endpoint/activation_cases/fixture_surface.rs` | `activation_tests.rs:188-230` | Supply valid cells for stronger frame validation |
| `endpoint/activation_cases/begin.rs` | `activation_tests.rs:255-450` | Port start/order/coherence assertions |
| `endpoint/activation_cases/identity.rs` | `activation_tests.rs:451-643` | Port generation/boot/focus assertions |
| `endpoint/activation_cases/rollback.rs` | `activation_tests.rs:644-815` | Port fence restart/rollback/resize assertions |
| `endpoint/activation_cases/successor.rs` | `activation_tests.rs:816-977` | Port rapid A-B-A successor assertions; preserve identity guards with SSH source |
| `endpoint/activation_cases/recovery.rs` | `activation_tests.rs:978-1139` | Port disconnected-source and latest-intent assertions |
| `endpoint/activation_cases/failure.rs` | `activation_tests.rs:1140-1305` | Port failed-release/deadline/healthy-target assertions |
| `endpoint/supervisor.rs` | Adapt `supervisor.rs:11-229,333-341` | Pollable bounded attempts replace spawned native connectors; independent backoff and stale-generation retirement |
| `src/client/shell.rs` | Adapt `shell/endpoints.rs:203-257,340-365,418-465` and `activation.rs` completion seam | Minimal qualified snapshot store; caller filters generations; no desktop chrome, keymaps or UI state |
| `src/client/shell/input.rs` | Adapt pane targeting from `shell.rs:86-97` | Qualified semantic input with selected-surface, generation, boot and coherent-projection checks |
| `src/client/surface_patch.rs` | `shell/surface_patch.rs:8-55,94-167` plus transactional commit | Preserve patch validation; clone before mutation; omit composed-ratatui fast path |
| `src/surface.rs` | New checked validation of upstream frame invariants | Reject invalid cell counts, hyperlink indices, cursors, geometry and duplicate pane IDs |
| `src/api.rs` | Projection of `api/schema.rs` activation methods and `api/schema/response.rs` result tags | Decode only activation-relevant JSON fields; reject unsupported result variants; not a bincode reimplementation |
| `src/client/endpoint_commands.rs` | Adapt `endpoint_commands.rs:262-297` | Typed success/error envelope and exact request-id correlation; no desktop command queue |
| `src/handshake.rs` | Adapt `client/handshake.rs:171-195,226-272`, timeout line 33 | Stable endpoint-only handshake, 60s remote deadline, full multi-machine admission predicate |
| `src/outbound.rs` | Adapt queue accounting from `endpoint/writer.rs:83-117` | Caller-sized bounded frame queue; no local sockets/worker threads; disconnect revokes pending input |
| `tests/lifecycle.rs` | New public-contract tests | Handshake admission/deadline, catalog invariants, independent supervisors and neutral Home |
| `tests/outbound.rs` | New public-contract tests | Exact framed queue delivery, overflow and disconnect revocation |
| `tests/selected_surface.rs`, `tests/support/activation_flow.rs` | New byte-transport scenario and regression tests | Complete presentation-fenced activation, atomic patches, and stale-projection input refusal |

The selected-surface regression first failed because newer metadata still
permitted input into an older surface. Adding exact snapshot/surface revision
coherence at semantic input routing made it pass; the test was not weakened.
Upstream's Local-only health test was intentionally changed to assert health
expiry for the SSH source that replaces Local. All 22 upstream activation
tests remain present, including rollback and successor-switch behavior.

## Golden-frame milestone

- `herdr-protocol/tests/support/client_samples.rs`: deterministic typed samples
  for all 21 frozen client variants, including all four semantic pane input
  variants. New test data using the extracted v0.9.0 types, not new wire types.
- `herdr-protocol/tests/support/server_samples.rs`: deterministic typed samples
  for all 21 frozen server variants plus the stable snapshot carrier. Reuses
  the exact upstream JSON snapshot fixture.
- `herdr-protocol/examples/capture_golden_frames.rs`: captures samples through
  the extracted upstream `write_message` encode path; no handcrafted binary.
- `herdr-protocol/tests/golden_frames.rs`: compares full encoded bytes against
  committed fixtures, decodes losslessly, verifies wire tags, and rejects trailing
  payload bytes. The fixture tests failed before capture and passed afterward.
- `herdr-protocol/tests/fixtures/golden/client-00.bin` through `client-20.bin`
  and `server-00.bin` through `server-21.bin`: 43 generated framed fixtures;
  numbers 00-20 are the corresponding frozen outer enum tags, server-21 is a
  second tag-20 control containing the stable JSON snapshot.
- `herdr-protocol/tests/fixtures/golden/README.md`: capture method, exact scope,
  and the distinction between encodable desktop records and executable behavior.

Original upstream SHA256 digest and tag assertions remain unchanged. No test
automatically updates fixtures when the codec changes.
