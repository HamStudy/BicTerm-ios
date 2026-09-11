# Herdr release traceability — §15 checklist to owning work

Task T20. Every row of `HERDR_IOS_INTEGRATION.md` §15 (acceptance and
release checklist) mapped to the task that owns it. Task numbering follows
`.omo/plans/bicterm-phase2-coder-ssh.md` (13–20); "phase 1" refers to the
SSH terminal foundation that predates the herdr plan (TOFU trust, jump
chains, key management, reconnect engine).

Disposition vocabulary — every row carries exactly one:

- **Delivered (Tn)** — implemented and covered by that task's committed tests.
- **Partial (Tn)** — implemented for the shipped scope; the row's full §15
  breadth needs later work, named in the note.
- **User QA** — requires a physical iPad / real network; handed to the user
  via `Docs/HERDR-DEVICE-QA-HANDOFF.md` (agents have no physical device).
- **OPEN** — not implemented in any planned task this phase. Listed
  explicitly so it is triaged, not silently dropped; scheduling it is a
  user decision. No claim of completeness is made for these rows.

Status legend for the plan itself: T16 is Phase-A-complete (live-server
criterion blocked by the zig-on-macOS-26 toolchain issue recorded in the
plan); everything else 13–19 is complete.

## Functional

| §15 row | Disposition |
|---|---|
| Password, public-key, passphrase-key, hardware-backed-key flows | Delivered (phase 1; herdr rides the same auth stack over T15's exec channel) |
| New, known, and changed host keys behave correctly | Delivered (phase 1 TOFU; herdr endpoints verified per-hop by the same `HostKeyVerifier`; per-host forget added by T20) |
| Non-default ports, IPv6 literals, DNS names, jump hosts | Delivered (phase 1; T15 exercises the exec channel over jump chains) |
| Channel is non-PTY and stdout is never text-normalized | Delivered (T15 — `HerdrSSHTransport` non-PTY exec; opaque-bytes contract pinned by tests) |
| Missing/incompatible Herdr → diagnostics only, never install/update | Delivered (T19 probe + `HerdrProbeDiagnosticView`; boundary tests `HerdrInstallBoundaryTests`; T20 App Review notes restate it) |
| Endpoint generation and codecs are negotiated, not assumed | Delivered (T13 handshake gates; T14 FFI admission; T20 fuzz `endpoint_json`) |
| Named sessions correctly quoted and isolated | Delivered (T15 `HerdrCommandBuilder` quoting vectors) |
| Full snapshot, incremental patch, focus, resize, shutdown | Partial (T16 snapshots + surfaces, T17 resize/focus routing; patch engine extracted and unit-tested in T13, but the FFI lane does not yet route `PaneSurfacePatch` frames — full-surface refresh is shipped instead; shutdown taxonomy T19) |
| Multiple clients and focus/ownership transitions | Partial (T16 machine-qualified identity + T19 per-endpoint reconnect; multi-client switching fences are OPEN, see Multi-machine) |
| Remote restart and network loss produce understandable recovery | Delivered (T19 `serverShutdown`/`transportLost` taxonomy + bounded reconnect with cancel) |
| iPad background/foreground reconnect preserves the workspace | Delivered on simulator (T19 bg/fg UI test); physical-device confirmation is User QA |

## Multi-machine support (v0.9.0)

| §15 row | Disposition |
|---|---|
| Two hosts + two named sessions without merging state | Partial (T16 endpoint-qualified state keyed by `HerdrEndpointID`; T19 independent-connection model tests; production "Add Machine" UI is OPEN) |
| Add Machine never invokes installation-capable setup | Delivered as a rule (probe is diagnostic-only, T19); the Add Machine surface itself is OPEN |
| Every endpoint negotiates generation/codecs/capabilities independently | Delivered in the core (T13 per-endpoint supervisors; one `HerdrClient` per endpoint in the app model, T16) |
| Missing optional methods disable only that endpoint's action | Partial (T13 registry health per endpoint; app-level action gating is OPEN with the multi-machine UI) |
| Colliding workspace/tab/pane IDs and agent names route correctly | Delivered (T16 `HerdrPaneRoutingKey` qualifies by endpoint+generation+boot; tests) |
| Inactive endpoints update metadata without pane streaming | Partial (T13 projection store supports it; app-side inactive-endpoint rendering is OPEN) |
| Switching freezes input until coherent target activation | Partial (T13 activation transaction + presentation fence extracted and tested; app-side A→B switching UX is OPEN) |
| Rapid switching/failed activation/late responses never misroute input | Partial (core-side stale-target rejection T17; switching-scenario app tests are OPEN with the switching UX) |
| Modifiers/mouse/selection/image paste stay machine-qualified through switching | Partial (T18 clipboard attribution is endpoint-qualified; mouse/selection are OPEN) |
| Independent bounded writes/health/retries with aggregate memory limits | Partial (per-endpoint reconnect budgets T19; the flooded/stalled/healthy three-endpoint soak is OPEN) |
| Reconnect does not steal selection; stale panes visibly stale | OPEN (server-authoritative selection not yet shipped) |
| Disable/remove disconnects only the chosen profile | Partial (T19 detach/disconnect per endpoint; profile-level disable UI is OPEN) |
| Multiple clients per tab follow last-interaction resize ownership | OPEN |
| Background/foreground recovery for several endpoints without reconnect storms | Partial (single-endpoint bg/fg delivered T19; multi-endpoint variant is User QA + OPEN for the storm-budget part) |

## Terminal rendering and input

| §15 row | Disposition |
|---|---|
| Structured surfaces bypass the VT parser | Delivered (T16 surface-provider rendering; never ANSI-re-encoded) |
| Frames/patches enforce boot, projection, base, and surface revisions | Delivered (T13/T16 coherence checks; T20 fuzz `patch_apply`) |
| Grapheme clusters, wide cells, non-US text render without width recomputation | Partial (T16/T17 render committed cells verbatim incl. CJK UI tests; skip/tail cell edge coverage rides on surface bytes as delivered — systematic grapheme matrix is OPEN) |
| Colors, style bits, cursor visibility/shape, alt-screen, hyperlinks | Partial (T16 cell colors + modifiers + cursor; hyperlink metadata renders as data — safe-open action is OPEN; blink/alt-screen behaviors are data-driven, untested) |
| Graphics tests (RGB/RGBA/PNG/cropping/z-order/…) | OPEN (graphics scenes not rendered this phase; wire types are preserved) |
| OSC 8 links require explicit safe open, no click stealing | OPEN |
| Title, bell, toast, sound notifications follow local settings | Partial (T16 notification strip renders title/toasts; bell/sound local settings are OPEN) |
| Hardware keyboard press/repeat/release, modifiers, navigation keys | Delivered (T17 key mapper + injector tests) |
| Unsupported keypad/media/Caps Lock ignored, not mis-serialized | Delivered (T17: unmapped keys never reach the wire — mapper tests) |
| Software keyboard/IME marked vs committed text, CJK, no duplicates | Delivered (T17 IME tests incl. CJK echo needles) |
| Scene focus transitions and resizes reach the remote in order | Delivered (T17 ordered input lane + resize ordering tests) |

## Mouse, trackpad, and touch

All rows in this section are **OPEN** — generation-1 shipped keyboard, paste,
and rendering; pointer/touch routing was not in any planned task (T17's
"pointer" scope was input-mapping plumbing only). Every row is triaged for a
future phase: left/middle/right sequences, hover policy, right-click
passthrough/context menu, wheel routing, pane focus/drag selection,
SGR pixel coordinates, pixel-to-cell downgrade, gesture dedup, auxiliary
buttons, touch selection defaults.

## Clipboard and media

| §15 row | Disposition |
|---|---|
| Pasteboard reads only after clear user intent | Delivered (T18 gesture-mediated reads; paste counts asserted zero pre-gesture) |
| Selection copy via `pane.selection.read` across wraps/scrollback | OPEN (server-authoritative selection not shipped; the remote clipboard banner path is the delivered copy story) |
| Empty, multiline, bracketed, non-ASCII, very large pastes tested | Delivered (T18 unit + UI vectors incl. 1 MiB cap classification) |
| Text paste is a semantic Paste event, never double-wrapped | Delivered (T18 byte-exact paste frames) |
| Paste into local overlays stays local | Delivered (T18 overlay-local paste tests) |
| Remote clipboard writes bounded, attributed, user-controlled | Delivered (T18 banner + per-host auto-copy opt-in default OFF) |
| Image paste formats, corrupt files, bombs, EXIF, 16 MiB boundary | Delivered (T18 corrupt/EXIF-strip/cap-minus-one/cap tests) |
| Clipboard/terminal content never in logs/analytics/crash metadata | Delivered (T18 redaction tests; T20 `LogRedactionAuditTests` locks the whole app) |

## Security and robustness

| §15 row | Disposition |
|---|---|
| Frame sizes, queues, render dimensions, patches, allocations bounded | Delivered (T20 `Docs/HERDR-HARDENING-AUDIT.md` with file:line enforcers; bincode claim-limit fix) |
| Malformed and truncated messages fail closed | Delivered (T20 malformed-suite 13 vectors; T13/T16 frame tests) |
| Decoder, patch engine, image handling, FFI fuzzed | Delivered (T20 four cargo-fuzz targets ≥10 min each; image handling covered by T18 vectors + T20 decode targets) |
| Private keys and secrets stay under Keychain/data-protection policy | Delivered (phase 1 stores; T20 sweep found no new herdr stored state outside UserDefaults clipboard opt-ins, which carry no secrets) |
| Command construction has injection test vectors | Delivered (T15 quoting vectors; rerun green in T20 regression) |
| Agent forwarding and unnecessary SSH features disabled by default | Delivered (phase 1 agent is per-request authorized; herdr exec channel requests no forwarding — T15) |
| Security review covers remote-server compromise | Delivered (T20 hardening audit treats the server as hostile: claim limits, malformed suite, clipboard drop path, surface rejection; residual risk rows are the OPEN items above) |

## iOS quality

| §15 row | Disposition |
|---|---|
| Physical-device tests across supported iPadOS versions | User QA (`Docs/HERDR-DEVICE-QA-HANDOFF.md`) |
| IPv6-only, LAN permission, Wi-Fi/cellular, VPN, captive networks | User QA (handoff §Network matrix) |
| Split View, Stage Manager, external display, rotation, memory pressure, thermal, low-power | User QA (handoff §Multitasking matrix) |
| VoiceOver, Dynamic Type, switch control, pointer, hardware keyboard, IME | Partial (simulator VoiceOver labels + Dynamic Type log delivered T16/T17; physical confirmation is User QA) |
| No unsupported background mode or private API | Delivered (T19 detach-on-background policy; no background modes declared — verified in T20 App Review notes prep; private-API sweep is covered by the T7 audit pattern rerun at release) |

## Licensing and store submission

| §15 row | Disposition |
|---|---|
| Herdr tag, commit, source hash, modified files recorded | Delivered (T13 `PROVENANCE.md`, `UPSTREAM_SOURCE.sha256`, `MODIFICATIONS.md`; updated by T14/T18/T20 ledger entries) |
| Target-specific Rust and Swift dependency inventories archived | Delivered (T13 `check.sh` inventories both iOS targets; T20 SBOM re-archived with build number) |
| All bundled source/assets have identified license + attribution | Delivered (T20 `Vendor/herdr/THIRD_PARTY_NOTICES.md` diffed against the linked-crate graph; Swift side in `DEPENDENCIES.md`) |
| Apache-2.0 and required licenses visible in acknowledgements | Delivered (T20 `AcknowledgementsView` renders the bundled notices) |
| No upstream NOTICE or file-level notice omitted | Delivered (T13 NOTICE scan in `PROVENANCE.md`; upstream ships no NOTICE file — scan result recorded) |
| App name/screenshots/text/icons do not imply Herdr endorsement | Delivered (descriptive use only; no upstream name/logo assets — T20 App Review notes) |
| App privacy answers match binary and server behavior | Delivered (no analytics, no telemetry; privacy answers drafted in `Docs/APP-REVIEW-NOTES.md` for the user to file) |
| Encryption/export-compliance answers and records complete | Delivered (T20 `Docs/HERDR-EXPORT-COMPLIANCE.md` memo draft; user files the App Store Connect answers) |
| App Review has a demo path and precise architecture notes | Delivered (T20 `Docs/APP-REVIEW-NOTES.md`; demo host is the user's to provision — noted inside) |

## Counts

76 rows (11 functional, 14 multi-machine, 11 terminal, 11 pointer/touch,
8 clipboard, 7 security, 5 iOS quality, 9 licensing). Delivered 40,
Partial 16, User QA 4, OPEN 16 (the pointer/touch section plus the named
future-phase items). Zero rows without a disposition.
