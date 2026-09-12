# Herdr hardening audit — bounds, fail-closed rules, and their enforcers

Task T20 (release hardening). Every bound the embedded Herdr client enforces
against a hostile or buggy remote server, with the file and line that
enforces it at the commit this document lands with. Line numbers move with
edits; the symbol names are the stable reference.

Verification attached to this audit:

- Malformed-server suite: `BicTermTests/Herdr/HerdrMalformedServerTests.swift`
  (13 vectors: truncated / oversized / out-of-order / trailing-data / garbage
  tag / hostile container claim / degenerate frames / malformed carriers).
- Fuzz targets: `Vendor/herdr/herdr-ios-ffi/fuzz/` (`length_parse`,
  `bincode_decode`, `endpoint_json`, `patch_apply`), ≥10 min each per run;
  evidence `.sisyphus/evidence/phase2-h20-fuzz-<target>.log`.
- Rust regression test for the claim-limit fix:
  `Vendor/herdr/herdr-protocol/tests/upstream_framing.rs`
  (`hostile_container_length_claim_is_rejected_not_allocated`).

## Wire framing

| Bound | Value | Enforced at |
|---|---|---|
| Inbound frame ceiling (default) | 2 MiB | `herdr-protocol/src/input.rs:9` (`MAX_FRAME_SIZE`); checked in `read_message` — `framing.rs:116` (`claimed_len > max_frame_size` → `FramingError::Oversized`) |
| Absolute frame ceiling (graphics) | 32 MiB | `herdr-protocol/src/input.rs:14` (`MAX_GRAPHICS_FRAME_SIZE`); FFI config validation `herdr-ios-ffi/src/factory.rs:29-37` rejects configs above it |
| Container-allocation claim limit | 32 MiB | `herdr-protocol/src/framing.rs:89-99` (`FramingDecodeConfig`, `framing_decode_config`) — see the finding below |
| Trailing bytes after a decoded message | rejected | `framing.rs:133` (`consumed != claimed_len` → `FramingError::Bincode`) |
| Truncated frame tail | buffered, not an error | `herdr-ios-ffi/src/frame.rs:17-19` (`UnexpectedEof` → `Partial`); buffer drained only per complete frame — `herdr-ios-ffi/src/client.rs:65` |
| Undecodable/oversized frame | connection fails closed | `herdr-ios-ffi/src/client.rs:70-76` (`inbound.clear()`, `Phase::Failed`, `HERDR_CODE_PROTOCOL_VIOLATION`) |

### Finding (fixed this task): unbounded decoder allocation claim

bincode 2.0.1 reserves `Vec`/`String` capacity from the decoded length varint
**before** reading elements, and only enforces that claim when the decode
configuration carries a limit (`claim_bytes_read` checks against
`Configuration::LIMIT`; with `NoLimit` it is a compiled-out no-op). The
framing path decoded with plain `standard()`, so a ≤2 MiB hostile frame could
claim a near-`u64::MAX` string length and drive an out-of-range allocation
request — observed live by the `length_parse` fuzz target (ASAN: "requested
allocation size 0x100000a00726574 exceeds maximum supported size").
Fix: the framing decode configuration now carries
`Limit<MAX_GRAPHICS_FRAME_SIZE>` (`framing.rs:99`), so any claim larger than
the largest conforming frame is rejected with `DecodeError::LimitExceeded`
before capacity is reserved. A hostile frame can still force **one bounded
transient allocation** ≤32 MiB before the slice reader fails — bounded,
fail-closed, and the same order as a legitimate maximum frame. Fuzz targets
and the Swift malformed-suite regression
(`testHostileContainerLengthClaimFailsClosedWithBoundedBuffer`) pin it.

## Surface and patch geometry

| Bound | Value | Enforced at |
|---|---|---|
| Frame cells completeness | `cells.len() == width × height` | `herdr-client-core/src/surface.rs:3-14` (`frame_valid`; also hyperlink indices and cursor-in-bounds) |
| Pane rectangles inside the frame | checked addition | `surface.rs:16-24` (`rect_fits`, `checked_add` — no overflow wrap) |
| Patch row fit | `x + len ≤ width`, `y < height` | `herdr-client-core/src/client/surface_patch.rs:8-13` (`row_fits_frame`, `saturating_add` + `min(u16::MAX)`) |
| Patch row target inside slice | `end ≤ cells.len()` | `surface_patch.rs:19-22` |
| Patch revision chain | `surface_revision == current + 1` | `surface_patch.rs:74` (`saturating_add`); base/boot/projection coherence same block |
| Patch atomicity | whole-patch apply or reject | `surface_patch.rs:125-131` (cloned frame; `validate_surface` on the result before commit) |
| Duplicate pane identity | rejected | `surface.rs:42-45` |
| Surface revision regression | rejected | `herdr-client-core/src/client/shell.rs:228-235` (`receive_surface`) |

Checked-arithmetic audit result: every hostile-input arithmetic path in the
protocol/core crates uses `checked_add`/`saturating_add`/`min` clamps (rows
above); no plain `+`/`*` on attacker-controlled lengths remains in the decode
or patch paths. The `length * size_of` claim multiplication inside bincode is
`checked_add`-guarded per bincode's `claim_bytes_read`.

## Outbound queues and buffers

| Bound | Value | Enforced at |
|---|---|---|
| Outbound message budget (default) | 256 messages | `herdr-ios-ffi/src/factory.rs:18` (`DEFAULT_OUTBOUND_MESSAGES`); enforced `herdr-client-core/src/outbound.rs:78` (`frames.len() >= limits.messages` → reject) |
| Outbound byte budget (default) | 4 MiB | `factory.rs:19` (`DEFAULT_OUTBOUND_BYTES`); enforced `outbound.rs:68-71` (checked add against `limits.bytes`) |
| App-side outbound byte budget | 24 MiB | `BicTerm/Herdr/HerdrSessionModel.swift:139` (headroom so a 16 MiB clipboard image plus envelope fits) |
| SSH bridge inbound bridge | 64 chunks × ≤32 KiB ≈ 2 MiB | `BicTermCore/Sources/BicTermCore/Herdr/HerdrSSHTransport.swift:36,79` (`inboundChunkLimit`, `bufferingNewest` — overflow surfaces as `bridgeOverflow` error, never silent loss) |
| Resize bounds | 1..=65535 per axis | `herdr-ios-ffi/src/abi.rs:294` (`herdr_client_resize` rejects 0 / >u16::MAX) |

## Clipboard and paste

| Bound | Value | Enforced at |
|---|---|---|
| OSC 52 payload cap (before base64 decode — no allocation) | 16 MiB decoded | `herdr-ios-ffi/src/clipboard.rs:20-22` (`len.div_ceil(4) * 3 > MAX_CLIPBOARD_IMAGE_PAYLOAD` → non-fatal `HERDR_CODE_CLIPBOARD_DROPPED`) |
| Outbound clipboard image cap | 16 MiB | `clipboard.rs:64-68` (`HERDR_CODE_INVALID_ARGUMENT` above cap; strict `>` so exactly 16 MiB is accepted) |
| Text paste cap (app) | 1 MiB | `BicTerm/Herdr/HerdrClipboard.swift:100,127` (`maxTextPasteBytes`, classify `.tooLarge`) |
| Image paste cap (app) | 16 MiB | `HerdrClipboard.swift:111` (`maxImagePayloadBytes`; FFI remains the authoritative backstop) |

## Session-model multi-endpoint budgets (herdr-support T10)

| Bound | Value | Enforced at |
|---|---|---|
| Aggregate reconnect-loop budget (every endpoint in one model) | 4 concurrent loops | `HerdrSessionModel.aggregateReconnectBudget` — default `HerdrReconnectBackoff.standard.maxAttempts` (the T19 per-endpoint budget reused as the model-wide cap, so N machines share budget/N); overflow queues FIFO in `pendingReconnects`, drained by `startNextQueuedReconnect` in `HerdrSessionLifecycle.swift` as loops settle |
| N-machine background suspend | one ~1 s drain window, not N | `suspendForSceneBackground` (`HerdrSessionLifecycle.swift`) — concurrent per-endpoint detaches interleave on the main actor; tests pin a 5-machine herd under 3 s |
| Retained per-machine surface caches (detached dimmed views) | 8 endpoints | `HerdrSessionModel.maxRetainedSurfaceCaches` (the `TerminalViewCache` cap-8 precedent); LRU eviction in `trimRetainedSurfaceCaches` — never evicts the selected endpoint's cache or a live runtime's current surface |
| Auth loss on reconnect (revoked key mid-session) | 1 attempt → typed `.authLost`, never auto-retried | `HerdrReconnectSource.live` (`HerdrSessionLifecycle.swift`) maps `sshEstablish`/`bridgeChannelFailed` carrying `.authenticationFailed`/`.authRequired` to `OpenError.authenticationLost`; the loop exits on the first throw |

## Probe and command construction

| Bound | Value | Enforced at |
|---|---|---|
| `herdr status` read cap | 4096 bytes | `BicTermCore/Sources/BicTermCore/Herdr/HerdrProbe.swift:91,117` (`statusQueryByteCap`, `head -c`) |
| Probe stdout/stderr caps | 16 KiB / 1 KiB | `HerdrProbe.swift:215-216` (`readBounded`) |
| Command quoting | POSIX single-quote routine, NUL rejected | `HerdrCommandBuilder` (see `BicTermCoreTests/.../HerdrCommandBuilderTests.swift`: hostile session names, hostile executable paths, embedded quotes, NUL bytes) |

## Handshake admission

| Rule | Enforced at |
|---|---|
| Welcome-only first frame, 60 s deadline | `herdr-client-core/src/handshake.rs:43-56` (`ExpectedWelcome`), `:34` |
| Generation, codec, capability gates | `handshake.rs:62-73` (generation 1, all four v1 codecs, surface-interest + health) |
| Second welcome after handshake | protocol violation | `herdr-ios-ffi/src/client.rs:125-130` |
| Snapshot carrier must be valid JSON | protocol violation | `herdr-ios-ffi/src/client.rs:181-192` |
| Client hello conservatism | generation 1, declared codecs only, `direct_graphics = false` | `herdr-ios-ffi/src/factory.rs:50-69` |

## Log hygiene

`BicTermTests/LogRedactionAuditTests.swift` fails the build if any app-source
logging call (`print`, `NSLog`, `os_log`, `Logger` methods) names
secret-bearing content (passwords, tokens, credentials, clipboard,
pasteboard, host keys, terminal/pane/cell content). The rule is removal, not
redaction. The herdr workspace logs carry only counts, revisions, and phase
transitions.
