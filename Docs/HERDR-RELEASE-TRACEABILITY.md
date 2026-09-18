# Herdr release traceability — §15 checklist to owning work

Task T20. Every row of `HERDR_IOS_INTEGRATION.md` §15 (acceptance and
release checklist) mapped to the task that owns it. Task numbering follows
the phase-2 work plan (tasks 13–20); "phase 1" refers to the
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
| Missing/incompatible Herdr → diagnostics only, never install/update | Delivered (T19 probe; revised 2026-09-18 by the herdr auto-install stages A–C — a MISSING binary on a supported platform now offers the pinned, sha256-verified herdr 0.9.0 install after a per-attempt consent prompt, see the remote-install amendment below, while an incompatible/present herdr stays diagnostic-only and the probe itself stays read-only; boundary enforced by the revised `HerdrInstallBoundaryTests`) |
| Endpoint generation and codecs are negotiated, not assumed | Delivered (T13 handshake gates; T14 FFI admission; T20 fuzz `endpoint_json`) |
| Named sessions correctly quoted and isolated | Delivered (T15 `HerdrCommandBuilder` quoting vectors) |
| Full snapshot, incremental patch, focus, resize, shutdown | Partial (T16 snapshots + surfaces, T17 resize/focus routing; patch engine extracted and unit-tested in T13, but the FFI lane does not yet route `PaneSurfacePatch` frames — full-surface refresh is shipped instead; shutdown taxonomy T19) |
| Multiple clients and focus/ownership transitions | Partial (T16 machine-qualified identity + T19 per-endpoint reconnect; multi-client switching fences are OPEN, see Multi-machine) |
| Remote restart and network loss produce understandable recovery | Delivered (T19 `serverShutdown`/`transportLost` taxonomy + bounded reconnect with cancel) |
| iPad background/foreground reconnect preserves the workspace | Delivered on simulator (T19 bg/fg UI test); physical-device confirmation is User QA |

## Multi-machine support (v0.9.0)

| §15 row | Disposition |
|---|---|
| Two hosts + two named sessions without merging state | Delivered (T16 endpoint-qualified state keyed by `HerdrEndpointID`; T19 independent-connection model tests; production Add Machine UI delivered by the herdr-support herd editor (T7) and coordinator (T8); two-live-server E2E `.sisyphus/evidence/herdr-support-t9.log`) |
| Add Machine never invokes installation-capable setup | Delivered (herd editor's Add Machine is a picker over existing SSH connections — herdr-support T7, evidence `.sisyphus/evidence/herdr-support-t7.log`; the probe stays diagnostic-only (T19), boundary enforced by `HerdrInstallBoundaryTests`) |
| Every endpoint negotiates generation/codecs/capabilities independently | Delivered in the core (T13 per-endpoint supervisors; one `HerdrClient` per endpoint in the app model, T16) |
| Missing optional methods disable only that endpoint's action | Partial (T13 registry health per endpoint; app-level action gating is OPEN with the multi-machine UI) |
| Colliding workspace/tab/pane IDs and agent names route correctly | Delivered (T16 `HerdrPaneRoutingKey` qualifies by endpoint+generation+boot; tests) |
| Inactive endpoints update metadata without pane streaming | Delivered (selection drives per-endpoint surface interest through `selectedEndpointID` — herdr-support T8 coordinator + T9 machine switcher; status/metadata per machine asserted in `.sisyphus/evidence/herdr-support-t8.log`, `.sisyphus/evidence/herdr-support-t9.log`) |
| Switching freezes input until coherent target activation | Delivered (T13 activation transaction + presentation fence; app-side switching shipped as the herd machine switcher — herdr-support T9, mid-activation switch coherence tests in `HerdSessionCoordinatorTests`, evidence `.sisyphus/evidence/herdr-support-t9.log`) |
| Rapid switching/failed activation/late responses never misroute input | Delivered (core-side stale-target rejection T17; app-side: late-connecting machines never steal selection and mid-activation switches keep both endpoints coherent — `HerdSessionCoordinatorTests`, herdr-support T8/T9, evidence `.sisyphus/evidence/herdr-support-t8.log`) |
| Modifiers/mouse/selection/image paste stay machine-qualified through switching | Partial (T18 clipboard attribution is endpoint-qualified; mouse/selection are OPEN) |
| Independent bounded writes/health/retries with aggregate memory limits | Partial (per-endpoint reconnect budgets T19; aggregate reconnect-loop budget and bounded retained-surface caches delivered by herdr-support T10, evidence `.sisyphus/evidence/herdr-support-t10.log`, bounds registered in `Docs/HERDR-HARDENING-AUDIT.md`; the flooded/stalled/healthy three-endpoint soak is OPEN) |
| Reconnect does not steal selection; stale panes visibly stale | OPEN (server-authoritative selection not yet shipped) — triage (2026-09-11): blocked-on-user-decision. Server-authoritative selection requires the live herdr-server path, which is blocked by the zig 0.15.x/libSystem link failure on macOS 26; options await a user decision. See `.omo/evidence/phase2-h16-server-fixture.md` (identical copy: `.sisyphus/evidence/phase2-h16-server-fixture.md`). |
| Disable/remove disconnects only the chosen profile | Delivered (T19 detach/disconnect per endpoint; profile-disable semantics shipped as the per-connection "Use Herdr" toggle (herdr-support T5) plus the herd editor's per-machine Remove/Add — the plan's adopted no-toggle decision — evidence `.sisyphus/evidence/herdr-support-t7.log`; herd deletion never touches connections or remote sessions, `HerdSessionCoordinatorTests`) |
| Multiple clients per tab follow last-interaction resize ownership | OPEN — triage (2026-09-11): blocked-on-user-decision. Exercising multiple live clients per tab requires the live herdr server, blocked by the zig 0.15.x/libSystem link failure on macOS 26; options await a user decision. See `.omo/evidence/phase2-h16-server-fixture.md`. |
| Background/foreground recovery for several endpoints without reconnect storms | Delivered (herdr-support T10: concurrent multi-endpoint background detach inside one drain window, foreground recovery paced by the aggregate reconnect budget with the selected machine first; evidence `.sisyphus/evidence/herdr-support-t10.log`. Physical-device confirmation remains part of the iOS-quality User QA rows below) |

## Terminal rendering and input

| §15 row | Disposition |
|---|---|
| Structured surfaces bypass the VT parser | Delivered (T16 surface-provider rendering; never ANSI-re-encoded) |
| Frames/patches enforce boot, projection, base, and surface revisions | Delivered (T13/T16 coherence checks; T20 fuzz `patch_apply`) |
| Grapheme clusters, wide cells, non-US text render without width recomputation | Partial (T16/T17 render committed cells verbatim incl. CJK UI tests; skip/tail cell edge coverage rides on surface bytes as delivered — systematic grapheme matrix is OPEN) |
| Colors, style bits, cursor visibility/shape, alt-screen, hyperlinks | Partial (T16 cell colors + modifiers + cursor; hyperlink metadata renders as data — safe-open action is OPEN; blink/alt-screen behaviors are data-driven, untested) |
| Graphics tests (RGB/RGBA/PNG/cropping/z-order/…) | OPEN (graphics scenes not rendered this phase; wire types are preserved) — triage (2026-09-11): not-applicable-with-reason. Graphics scene rendering was not in any planned phase-2 task (T16-T18 shipped text surfaces only); wire types are preserved so no data is lost. Scheduling graphics rendering is a future-phase user decision, not a phase-2 gap. |
| OSC 8 links require explicit safe open, no click stealing | OPEN — triage (2026-09-11): not-applicable-with-reason. Hyperlink metadata currently renders as inert data (T16), so no click stealing is possible this phase; the explicit safe-open action was not in any planned phase-2 task and is a future-phase user decision. |
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

Triage (2026-09-11) — all 11 pointer/touch rows share one classification:
not-applicable-with-reason. Pointer and touch routing was deliberately
outside every planned phase-2 task; T17's "pointer" scope was input-mapping
plumbing only (see T17 evidence `.sisyphus/evidence/phase2-h17-*` and the
plan's task-17 section). Generation-1 shipped keyboard, paste, and
rendering. These rows are not blocked by the zig/live-server issue (input
routing is client-side); they are unscheduled future-phase work awaiting a
user decision. Row-by-row: (1) left/middle/right sequences, (2) hover
policy, (3) right-click passthrough/context menu, (4) wheel routing,
(5) pane focus/drag selection, (6) SGR pixel coordinates, (7)
pixel-to-cell downgrade, (8) gesture dedup, (9) auxiliary buttons,
(10) touch selection defaults, (11) pointer/touch routing end-to-end —
each not-applicable-with-reason as stated above.

## Clipboard and media

| §15 row | Disposition |
|---|---|
| Pasteboard reads only after clear user intent | Delivered (T18 gesture-mediated reads; paste counts asserted zero pre-gesture) |
| Selection copy via `pane.selection.read` across wraps/scrollback | OPEN (server-authoritative selection not shipped; the remote clipboard banner path is the delivered copy story) — triage (2026-09-11): blocked-on-user-decision. `pane.selection.read` is a server-authoritative method requiring the live herdr-server path, blocked by the zig 0.15.x/libSystem link failure on macOS 26; options await a user decision. See `.omo/evidence/phase2-h16-server-fixture.md`. The delivered copy story (T18 remote clipboard banner, evidence `.sisyphus/evidence/phase2-h18-paste-audit.log`) is unaffected. |
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
8 clipboard, 7 security, 5 iOS quality, 9 licensing). Delivered 46,
Partial 10, User QA 4, OPEN 16 (the pointer/touch section plus the named
future-phase items). Zero rows without a disposition.

Amendment (2026-09-12, herdr-support T10/T11): six multi-machine rows
flipped Partial → Delivered with evidence pointers above (two-hosts,
inactive-endpoint metadata, both switching rows, profile-disable
semantics, multi-endpoint bg/fg storm budget).

Triage addendum (2026-09-11): the 16 OPEN rows now carry inline `triage:`
annotations (5 table rows) or a section-level triage list (11
pointer/touch rows). Summary: 3 blocked-on-user-decision (live
herdr-server path; zig 0.15.x/libSystem link failure, see
`.omo/evidence/phase2-h16-server-fixture.md`), 13
not-applicable-with-reason (deliberately unscheduled future-phase scope).
None were reclassified as closed; no original row text was altered.

## T19 replay-vs-live classification (2026-09-11)

T19's detach/re-attach persistence evidence
(`.sisyphus/evidence/phase2-h19-persistence-iphone.log`,
`phase2-h19-persistence-ipad.log`) used committed-frame replay through the
app's own surface pipeline (the `herdr-replay-ready` fixture path in the
UI tests), not a live herdr server. Classification: this is the documented
zig-blocked environment item, not a silently weakened test. The live
herdr-server path is blocked by the zig 0.15.x/libSystem link failure on
macOS 26, recorded with a minimal reproduction and user options in
`.omo/evidence/phase2-h16-server-fixture.md`. Replay exercises the real
persistence, reducer, and re-render code paths against committed frames;
what it does not prove is live-server frame generation. Closing that gap
is one of the user decisions listed in the h16 fixture doc.

## Live-fixture amendment (2026-09-12, herdr-support T3)

The zig blocker recorded above no longer applies to the fixture path:
`scripts/herdr-server-fetch.sh` now fetches the pinned prebuilt herdr
v0.9.0 release binary (sha256-verified against
`Fixtures/herdr/server-0.9.1.sha256`; the server is never built from
source), and `scripts/fixtures-up.sh` runs one herdr server per fixture
port. Live E2E against both servers shipped with herdr-support T6 (mode A)
and T9 (herd switching; evidence `.sisyphus/evidence/herdr-support-t6.log`,
`.sisyphus/evidence/herdr-support-t9.log`). The three OPEN rows above that
cite the zig-blocked live-server path (server-authoritative selection,
multi-client resize ownership, `pane.selection.read`) remain OPEN because
those server-side features are not exercised by the shipped flows — their
scheduling is still a user decision, now unconstrained by the fixture.

## herdr-embed T7 amendment (2026-09-13)

The shipped herdr surface is the embedded real herdr client (T4–T7); the
native SwiftUI herdr workspace interior (`HerdrWorkspaceView`,
`HerdMachineSwitcher` / `HerdWorkspaceChromeView`, `HerdrPaneSurfaceView`,
`HerdrInputField`, `HerdrKeyMapper`, `HerdrImagePasteSheet`,
`HerdrDiagnosticView`, `HerdrProbeDiagnosticView`, the Mode-A native
`HerdrConnectCoordinator`) retired behind the embed. Rows above that
named a native component are now superseded-by-embed:

- **Missing/incompatible Herdr → diagnostics only** — flip:
  delivered (T19 probe; the embed runtime maps every connector error onto
  the same `HerdrDiagnostic` kinds — authLost / transportLost /
  incompatibleGeneration — and renders them inline as the embed view's
  `.failed` phase with a `Label(diagnostic.title)` and the typed message;
  `HerdrEmbedTransportTests` covers every mapping). Boundary tests
  (`HerdrInstallBoundaryTests`) and T20 App Review notes unchanged.
- **Two hosts + two named sessions without merging state** — flip the
  disposition footnote: the multi-machine selection/health UI is the
  embedded client's own sidebar (T6 herd seeding via
  `HerdrEmbedHerdSeeder.links(for:)`); the native `HerdMachineSwitcher` /
  `HerdWorkspaceChromeView` retired. Live two-machine E2E moved into
  `HerdrEmbedHerdTests` (evidence `.sisyphus/evidence/herdr-embed-t6.log`).
- **Inactive endpoints update metadata without pane streaming** — flip:
  the real herdr client owns selection/surface-interest; the native
  per-machine status-chip UI retired.
- **Switching freezes input until coherent target activation** — flip the
  app-side footnote: the embed runtime's owner-scoped `startIfNeeded`
  (T6) is the activation gate; herd-machine takeover coherence covered by
  `HerdrEmbedHerdTests.testOpeningSecondHerdClosesFirstAndIsolatesSocketsAndCatalog`.
- **Hardware keyboard / modifiers / navigation keys** — flip: the embed
  TUI receives input through the SwiftTerm delegate on
  `HerdrTUIHostingView` (no app-layer `HerdrKeyMapper` / `HerdrInputField`);
  `HerdrEmbedHostingTests.testCellSizeQueryIsAnsweredBySwiftTermThroughInputPath`
  + `testLayoutResizeReachesSessionWinsize` cover the path.
- **Software keyboard / IME / CJK / no duplicates** — flip the footer:
  the embed TUI is the IME-committed surface; the CJK needles moved into
  the embed TUI's own logs (out of the prior echo-strip assertion).
- **Scene focus transitions and resizes reach the remote in order** —
  flip: `HerdrEmbedRuntime.writeInput` + `setWinsize` + the embed crate's
  TIOCSWINSZ/SIGWINCH contract; `HerdrEmbedHostingTests.testLayoutResize…`
  asserts the round trip.

The connector / coordinator / endpoint-model / probe pieces referenced
(`HerdrEndpointConnector`, `HerdSessionCoordinator` `liveLookup`,
`HerdrEndpointModels`, `HerdrProbe`) are **kept** as embed-shared infra:
the embed runtime owns TOFU / probe / bridge per machine through them,
and `HerdSessionCoordinator.liveLookup` is the connection resolver the
embed herd seeder calls. `HerdrEmbedWorkspaceView` is the only herdr UI;
its chrome (header `Herdr — {label}`, `embedded client running` status,
`Disconnect` button, `EmbedTrustPromptPresenter` for TOFU) is the
deliverable, and `HerdrConnectUITests` (rewritten T7) exercises it on
both simulators. Evidence: `.sisyphus/evidence/herdr-embed-t7.log`,
`.sisyphus/evidence/herdr-embed-t7/`.

## herdr remote-install amendment (2026-09-18, stages A–C)

The §15 row "Missing/incompatible Herdr → diagnostics only, never
install/update" is superseded for the MISSING-binary case only: when the
probe finds no herdr binary on an otherwise-supported host (linux/macos ×
x86_64/aarch64), both bring-up paths (herd via `HerdSessionCoordinator`,
embed via `HerdrEmbedTransportCoordinator.establishOne`) present a
per-attempt consent sheet (`HerdrInstallConsentView`: host, version,
destination, source) and, on approval, `HerdrRemoteInstaller` (stage A,
`a1772f9`) installs the pinned herdr 0.9.0 release over the live SSH
carrier — upstream's own attach.rs prepare/tee/chmod 755/mv upload model
— after which the connector re-probes with the same search paths. Decline
is a quiet typed `.installDeclined`; install failure is a typed
`.installFailed` diagnostic. A present-but-incompatible herdr never
proposes (no replace/upgrade flows), and the probe itself stays read-only
(`HerdrProbe.swift` boundary doc). The revised
`HerdrInstallBoundaryTests` (stage C) enforces the contract: forbidden
install vocabulary everywhere except the installer's own comment-stripped
file, the deliberate sequence confined to that file, and the installer
family reachable only from the connector's install-offering variants,
its binary-provider seam, the composition root, and the embed bring-up
path.

### Release-pin provenance

- Source: the `0.9.0` entry of the `releases` map in
  `https://herdr.dev/latest.json` (upstream's stable update manifest),
  fetched 2026-09-18. Recorded as compile-time constants in
  `BicTermCore/Sources/BicTermCore/Herdr/HerdrReleasePins.swift`
  (download URLs follow
  `https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-<os>-<arch>`;
  the exact per-target URLs live in `HerdrReleasePins.asset(for:)`).
  Bumping the pin is a deliberate, reviewed act: version, the four asset
  entries, and the fixture lockfile move together.
- The four pinned targets and their sha256 values:
  - linux-x86_64:
    `4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f`
  - linux-aarch64:
    `9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2`
  - macos-x86_64:
    `d0c920b2a126a74809fa1491411c9a097a44786cac9c2ca51b818a995581cf16`
  - macos-aarch64:
    `32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17`
- The macos-aarch64 pin is byte-identical to the committed fixture
  lockfile `Fixtures/herdr/server-0.9.0.sha256` (same artifact family);
  `HerdrRemoteInstallerTests.testMacosAarch64PinMatchesCommittedFixtureLockfile`
  asserts the two never drift apart silently, so the offline fixture
  round-trip installs exactly the pinned bytes.

