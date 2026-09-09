# Coder acceptance matrix

Gate: INCOMPLETE. FAIL includes unverified requirements.

Continuation: `.sisyphus/evidence/phase2-g12-repair-brief.md` records repaired
UI root causes and fresh regressions. No additional full normative outcome
was established, so the row dispositions below are unchanged.

This is a blocked-gate inventory, not a compatibility declaration. The 34
normative rows below are generated directly from the read-only spec section
18.1. For unexecuted scenarios, the command is the executed gate-inventory
check, not a claimed scenario run. The brief distinguishes missing evidence
from observed regression failures. No NOT-LOCAL classification hides a
locally runnable scenario that remains unexecuted.

Compatibility scope is session/exec/PTY/resize only. SFTP and TCP forwarding
are excluded by the v1 session-channel guardrail in
`.omo/plans/bicterm-phase2-coder-ssh.md`, Scope / Out of scope, line 32,
and task 12, line 465. They are not optional live-deployment work.

### A01

| Test | Expected result |
|---|---|
| Valid user token, one running agent | OpenSSH can execute a command through the raw adapter. |

- Status: FAIL
- Command: `Fixtures/run/coder-bin/coder ssh --disable-autostart --wait auto --log-dir "$PWD/.scratch/g12-cli" bicterm-host -- printf bicterm-g12-cli-ok`
- Evidence: `.sisyphus/evidence/phase2-g12-cli-reference.log`
- Reason: -
- Detail: Official pinned CLI command succeeded in 0.272 seconds; live native NIOSSH conformance also passed. Neither establishes OpenSSH execution through BicTerm's raw adapter, so the entire normative row is not PASS.

### A02

| Test | Expected result |
|---|---|
| Invalid/expired user token | Actionable authentication-required error, no endless retry and no token on stdout. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Core authentication classification tests passed, but this session did not execute the invalid-token scenario against T6 and audit stdout for that run. No full-row PASS claimed.

### A03

| Test | Expected result |
|---|---|
| Valid user but no SSH permission | Respect denial, including authorization-hidden 404 behavior. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Authorization-hidden 404 was not exercised against a valid user lacking SSH permission. Generic forbidden and missing-workspace unit tests are insufficient substitutes.

### A04

| Test | Expected result |
|---|---|
| Multiple agents without a selector | Explicit ambiguity error; no first-agent guessing. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Running-workspace ambiguity unit test and Coder agent-selection UI suite passed; the required multiple-agent T6 deployment scenario remains unexecuted.

### A05

| Test | Expected result |
|---|---|
| Exact agent name and UUID selection | Correct current-build agent is reached. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Saved-agent selection UI coverage passed, but exact-name and exact-UUID selection were not both exercised against distinct current-build T6 agents.

### A06

| Test | Expected result |
|---|---|
| Unknown or old-build agent UUID | Clear failure/re-resolution path; no accidental access to another workspace. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Stale-selection UI coverage passed; old-build UUID isolation against the native deployment was not executed.

### A07

| Test | Expected result |
|---|---|
| Stopped workspace, start disabled | No start POST occurs. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Coder agent-selection UI start-policy coverage passed with DEBUG fixtures. No T6 request ledger proving zero start POSTs was captured in this session.

### A08

| Test | Expected result |
|---|---|
| Stopped workspace, start explicitly enabled | One accepted start; build followed to the correct current agent. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: DEBUG fixture start-policy coverage passed; one accepted real start followed to its current agent was not executed and counted against T6.

### A09

| Test | Expected result |
|---|---|
| Start POST response lost | State rechecked before retry; no duplicate blind mutation. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Start-response-loss injection and subsequent authoritative-state recheck were not executed. A successful normal start is not evidence for this outcome.

### A10

| Test | Expected result |
|---|---|
| Dormant workspace or parameter mismatch | Explicit lifecycle/parameter action required; no silent changes. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Neither a dormant native workspace nor a template-parameter mismatch was exercised. These remain locally runnable acceptance gaps, not NOT-LOCAL items.

### A11

| Test | Expected result |
|---|---|
| Blocking and nonblocking startup scripts | `auto` waiting follows script policy. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: The native fixture template has no startup script or start_blocks_login variant. The CLI auto-wait option was inspected, but neither required template variant was provisioned or tested.

### A12

| Test | Expected result |
|---|---|
| Startup timeout/error | Bounded, informative failure or explicit diagnostic-login override. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: A failing or timing-out startup script was not provisioned. A bounded tailnet dial timeout does not prove startup-script timeout/error semantics.

### A13

| Test | Expected result |
|---|---|
| Direct UDP path available | Session works; diagnostics can show direct connectivity when selected. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Live shell conformance passed without capturing an asserted direct path. Synthetic direct-path event observation is not proof of direct UDP connectivity.

### A14

| Test | Expected result |
|---|---|
| Direct UDP blocked | Session works through DERP. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Relay-only bridge configuration was not forced during this session's live conformance run. No DERP-only PASS inferred from a working shell.

### A15

| Test | Expected result |
|---|---|
| Server disables direct connections | No user preference bypasses server policy. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Server help was inspected; server-side direct-disable policy was not activated and challenged by a client preference.

### A16

| Test | Expected result |
|---|---|
| DERP custom upgrade rejected, WS permitted | Compatible WebSocket relay fallback works. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: A proxy rejecting custom upgrades while accepting WebSockets was not installed. This is an unexecuted local harness requirement, not an established environment limitation.

### A17

| Test | Expected result |
|---|---|
| Server forces DERP WebSockets | Initial relay setup uses the required transport. |

- Status: FAIL
- Command: `Fixtures/run/coder-bin/coder server --help`
- Evidence: `.sisyphus/evidence/phase2-g12-server-help.log`
- Reason: -
- Detail: The pinned server exposes --derp-force-websockets. Help inspection is only a capability probe; this flag was not enabled and initial relay transport was not observed. It cannot honestly be classified unforceable.

### A18

| Test | Expected result |
|---|---|
| Private CA/reverse proxy | Approved trust/auth works on REST, coordinator, and relay; no blanket TLS bypass. |

- Status: NOT-LOCAL
- Command: `test -n "${CODER_PRIVATE_CA_FILE:-}" && test -f "${CODER_PRIVATE_CA_FILE:-}"`
- Evidence: `.sisyphus/evidence/phase2-g12-locality.log`
- Reason: needs-private-CA
- Detail: No approved CA file was supplied through CODER_PRIVATE_CA_FILE; T6 uses loopback HTTP. Optional authorized private-CA/reverse-proxy validation must cover REST, coordinator, and relay without TLS bypass.

### A19

| Test | Expected result |
|---|---|
| Dynamic DERP map update | Connection manager applies updates without corrupting the SSH stream. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Dynamic DERP map replacement was not injected while checking SSH stream integrity. No deployment requirement established; local feasibility remains to be exercised.

### A20

| Test | Expected result |
|---|---|
| Coordinator connection reset | Appropriate control reconnect; no command replay. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Lifecycle unit tests passed, but no live coordinator reset with a command-execution counter was run. No-replay is not inferred from suspend/resume alone.

### A21

| Test | Expected result |
|---|---|
| Invalid/expired resume token | Retry without resume token, not a spurious login prompt. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Swift resume-token classification tests passed. A real expired resume token was not injected to observe SDK retry without that token.

### A22

| Test | Expected result |
|---|---|
| Agent restart/workspace rebuild | Existing session ends appropriately; new connection resolves the right agent. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Real agent restart or workspace rebuild was not performed during an active session. Fake agent-gone errors do not establish subsequent current-build resolution.

### A23

| Test | Expected result |
|---|---|
| Network change or suspend/resume | Bounded recovery or clear reconnect error; no leaked sessions. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Live transport suspend/resume and close conformance passed on both destinations. Full iPad UI regression failed in scene flows, and the combined no-leaked-session recovery outcome was not fully audited.

### A24

| Test | Expected result |
|---|---|
| Interactive terminal resize | Terminal dimensions update correctly through the chosen SSH client. |

- Status: PASS
- Command: `DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-core-iphone-retry.log' scripts/test-core.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-core-iphone-retry.log`
- Reason: -
- Detail: CoderTransportConformanceTests.testResizeIsObserved passed against the real native fixture, observing remote stty dimensions. The same live test also passed in phase2-g12-core-ipad.log.

### A25

| Test | Expected result |
|---|---|
| Noninteractive binary stdout | Byte-exact output; no CRLF/text transformations or debug banners. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Live conformance uses a PTY shell and text markers. No non-PTY binary byte comparison was run; this row is not scope-excluded merely because exec work remains.

### A26

| Test | Expected result |
|---|---|
| Remote command exit status/stderr | Preserved by the downstream/native SSH implementation. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: No separate stderr and nonzero remote exit-status assertions were exercised through BicTerm's native downstream implementation.

### A27

| Test | Expected result |
|---|---|
| Large output and transfers greater than 4 MiB | Complete streaming transfer; coordinator limits not misapplied to SSH data. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: No greater-than-4-MiB end-to-end transfer with byte count and digest comparison was executed. Small shell markers are insufficient.

### A28

| Test | Expected result |
|---|---|
| SFTP and TCP forwarding when permitted | Work through the same raw transport. |

- Status: NOT-LOCAL
- Command: `grep -n "NO SFTP/forwarding\|scope-explained" .omo/plans/bicterm-phase2-coder-ssh.md`
- Evidence: `.sisyphus/evidence/phase2-g12-locality.log`
- Reason: scope-explained
- Detail: Permanent v1 session-channel-only guardrail: plan Scope / Out of scope line 32 and T12 line 465. No SFTP or TCP-forwarding compatibility claim; not an optional live item.

### A29

| Test | Expected result |
|---|---|
| File transfer/forwarding denied by server | Denial surfaced; no alternate-endpoint bypass. |

- Status: NOT-LOCAL
- Command: `grep -n "NO SFTP/forwarding\|scope-explained" .omo/plans/bicterm-phase2-coder-ssh.md`
- Evidence: `.sisyphus/evidence/phase2-g12-locality.log`
- Reason: scope-explained
- Detail: Permanent v1 session-channel-only guardrail: plan Scope / Out of scope line 32 and T12 line 465. File-transfer/forwarding channels are excluded, including server-denial interoperability; not an optional live item.

### A30

| Test | Expected result |
|---|---|
| Stdin EOF with trailing remote output | Half-close permits output to drain; no truncation. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: No stdin half-close followed by trailing-output drain test was run through the live bridge. Full close conformance is a different outcome.

### A31

| Test | Expected result |
|---|---|
| Cancellation, stdout failure, peer EOF | Both copy directions and network/controller resources terminate. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Close and partial-dial cleanup coverage passed, but stdout-write failure and both copy directions under peer EOF were not exercised together as required.

### A32

| Test | Expected result |
|---|---|
| Concurrent distinct profiles/users | No credential or peer-connection cross-contamination. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Generation-isolation unit tests passed. Concurrent live profiles belonging to distinct users were not created; cross-user peer isolation remains unverified.

### A33

| Test | Expected result |
|---|---|
| Usage lifecycle | Heartbeat begins only for real use and stops on close. |

- Status: PASS
- Command: `DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-core-iphone-retry.log' scripts/test-core.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-core-iphone-retry.log`
- Reason: -
- Detail: UsageHeartbeatTests passed all seven deterministic heartbeat lifecycle tests, using the injected clock and request boundary. This is behavioral unit evidence, not a 60-second live-deployment heartbeat observation.

### A34

| Test | Expected result |
|---|---|
| Logging/security audit | No user tokens, resume tokens, private keys, or terminal contents in logs. |

- Status: FAIL
- Command: `ruby scripts/verify-coder-matrix.rb --gate`
- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`
- Reason: -
- Detail: Existing token-bearing-source audits passed, and AppStore exact bridge/SDK isolation was verified separately. No complete sentinel audit covering user/resume tokens, keys, and terminal contents across all T12 scenario logs was executed.
