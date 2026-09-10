# Coder acceptance matrix

Gate: execution complete; approval remains with Atlas.

Latest evidence: `.sisyphus/evidence/phase2-g12-final-progress-brief.md` records
green full UI regressions and additional native protocol execution. There are
31 PASS, 3 NOT-LOCAL and zero FAIL rows. Final native regressions and the
sentinel logging audit are recorded in phase2-g12-final-acceptance-brief.md.

This is an acceptance evidence inventory, not a compatibility declaration. The 34
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

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: OpenSSH executes printf through the production CoderNet UDS translation proxy into the native v2.36.4 agent, with none authentication and no PTY; exact stdout and zero exit status asserted. Host build command is bash scripts/test-coder-raw.sh. The separate A31 case fails later in the same suite.

### A02

| Test | Expected result |
|---|---|
| Invalid/expired user token | Actionable authentication-required error, no endless retry and no token on stdout. |

- Status: PASS
- Command: `DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" ONLY_TESTING='BicTermCoreTests/CoderNativeAuthAcceptanceTests' EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-b-auth-native-green.log' scripts/test-core.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-auth-native-green.log`
- Reason: -
- Detail: The real native server returns HTTP 401 to the Swift transport using an invalid user-token sentinel. The request ledger asserts exactly one response, the transport throws authRequired before any tunnel allocation/dial, and credentials/server metadata are not mutated. The executed log was checked for absence of the token sentinel; see phase2-g12-b-auth-audit.log.

### A03

| Test | Expected result |
|---|---|
| Valid user but no SSH permission | Respect denial, including authorization-hidden 404 behavior. |

- Status: PASS
- Command: `ruby scripts/test-coder-permission.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-b-permission.log`
- Reason: -
- Detail: A newly created distinct user authenticates successfully (users/me 200) but receives 404 for the owner's existing agent connection endpoint. The owner receives 200 before and after. The production bridge refuses the outsider dial with no socket and retains the 404 diagnosis without leaking the credential. The temporary user is deleted after the test.

### A04

| Test | Expected result |
|---|---|
| Multiple agents without a selector | Explicit ambiguity error; no first-agent guessing. |

- Status: PASS
- Command: `bash scripts/test-coder-selection.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-selection-acceptance.log`
- Reason: -
- Detail: The native g12-selection workspace has connected main and sidecar agents. Automatic resolution throws agentUnavailable instead of selecting the first candidate; the native test asserts both agents exist and are connected before exercising rejection. Existing explicit-selection UI behavior is preserved.

### A05

| Test | Expected result |
|---|---|
| Exact agent name and UUID selection | Correct current-build agent is reached. |

- Status: PASS
- Command: `bash scripts/test-coder-selection.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-selection-acceptance.log`
- Reason: -
- Detail: Four real CoderTransport connections select main and sidecar by exact name and by UUID. Each executes a command that reads its agent-specific BICTERM_ACCEPTANCE_AGENT environment value; the returned marker must match the requested agent. The failing-first native case exposed ignored protocol options, now fixed in Core resolution and transport wiring.

### A06

| Test | Expected result |
|---|---|
| Unknown or old-build agent UUID | Clear failure/re-resolution path; no accidental access to another workspace. |

- Status: PASS
- Command: `bash scripts/test-coder-selection.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-selection-acceptance.log`
- Reason: -
- Detail: The wrapper snapshots actual agent identities, rebuilds the workspace to create a new generation, and tests the absent old UUID. It requires reconnectRequired, not a replacement dial. A separate unknown-UUID case also supplies a valid saved name and proves no fallback. Public before/after IDs are retained in phase2-g12-b-selection-previous.log and phase2-g12-b-selection-current.log.

### A07

| Test | Expected result |
|---|---|
| Stopped workspace, start disabled | No start POST occurs. |

- Status: PASS
- Command: `DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" ONLY_TESTING='BicTermCoreTests/CoderNativeStartPolicyAcceptanceTests' EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-b-start-disabled.log' scripts/test-core.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-start-disabled.log`
- Reason: -
- Detail: The native bicterm-stopped workspace is confirmed stopped. Connecting with coder.startPolicy=false returns reconnectRequired, and the real HTTP ledger contains only GET requests (zero mutations/start POSTs). The already-verified UI policy guard remains unchanged.

### A08

| Test | Expected result |
|---|---|
| Stopped workspace, start explicitly enabled | One accepted start; build followed to the correct current agent. |

- Status: PASS
- Command: `bash scripts/test-coder-start.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-start-native.log`
- Reason: -
- Detail: CoderWorkspaceStarter starts a real stopped acceptance workspace. Its request ledger asserts exactly one POST returning 201, follows the build and agent to ready, and verifies the connected agent ID differs from the prior stopped generation. A repository-local watcher launches the regenerated native agent script without issuing another build mutation.

### A09

| Test | Expected result |
|---|---|
| Start POST response lost | State rechecked before retry; no duplicate blind mutation. |

- Status: PASS
- Command: `bash scripts/test-coder-start.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-start-native.log`
- Reason: -
- Detail: The loader forwards the real native start POST, observes acceptance (201), then injects response loss at the network boundary. The next request must be an authoritative GET of that workspace. The complete ledger asserts exactly one POST, zero duplicate mutations, and successful readiness of the new agent.

### A10

| Test | Expected result |
|---|---|
| Dormant workspace or parameter mismatch | Explicit lifecycle/parameter action required; no silent changes. |

- Status: PASS
- Command: `bash scripts/test-coder-actions.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-actions-green.log`
- Reason: -
- Detail: Real dormant and required-parameter-mismatch workspaces both return explicit action instructions with GET-only ledgers, zero start POSTs, and unchanged workspace detail. The native red run proved an unguarded start POST clears dormancy; the starter now refuses after a fresh workspace read. See phase2-g12-b-actions-brief.md for fixture setup, red/green evidence, and passing start/recheck regressions. Existing UI views remain unchanged.

### A11

| Test | Expected result |
|---|---|
| Blocking and nonblocking startup scripts | `auto` waiting follows script policy. |

- Status: PASS
- Command: `bash scripts/test-coder-startup.sh && bash scripts/test-coder-startup-policy.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-auto-final.log`
- Reason: -
- Detail: Both real start_blocks_login variants are provisioned with a script held on a repository-local release marker. Blocking connections remain pending until release; nonblocking connections complete while the script is still held. Native Core tests cover already-running workspaces, and app-side starter tests cover explicit starts. Evidence also includes phase2-g12-b-startup-tests.log and each variant's captured script-policy metadata. The pinned v2.36.4 CLI independently matches both policies with --wait auto; see phase2-g12-b-startup-cli-comparison.log and phase2-g12-b-startup-verification.md.

### A12

| Test | Expected result |
|---|---|
| Startup timeout/error | Bounded, informative failure or explicit diagnostic-login override. |

- Status: PASS
- Command: `bash scripts/test-coder-startup.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-startup-tests.log`
- Reason: -
- Detail: Real script variants exit with error and exceed their one-second script timeout. Core refuses to connect and reports remoteStartupFailed retaining start_error or start_timeout in its actionable description. The native red run previously connected silently in both states; the green run rejects them. Waiting uses a monotonic ten-minute bound and cancellation-aware sleeps, not a tailnet timeout substitute.

### A13

| Test | Expected result |
|---|---|
| Direct UDP path available | Session works; diagnostics can show direct connectivity when selected. |

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: Real shell/binary traffic succeeded, and the bridge's observed networkPathChanged event was asserted to report direct. This is not a synthetic path event.

### A14

| Test | Expected result |
|---|---|
| Direct UDP blocked | Session works through DERP. |

- Status: PASS
- Command: `CODER_GATE_RELAY_ONLY=1 ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-relay-current.log`
- Reason: -
- Detail: BlockEndpoints is enabled through the production relay_only configuration. Real command, binary, stderr/status and 5 MiB transfer cases passed, with an asserted relayed path event. The separate stdout-failure case remains A31 FAIL.

### A15

| Test | Expected result |
|---|---|
| Server disables direct connections | No user preference bypasses server policy. |

- Status: PASS
- Command: `bash scripts/test-coder-derp.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-final-derp-retry.log`
- Reason: -
- Detail: Both executed proxy modes restart the native server with CODER_BLOCK_DIRECT=true, leave the client relay_only=false, and require an observed relayed path while executing the raw cases. The raw child evidence is phase2-g12-final-derp-fallback-raw.log and phase2-g12-final-derp-forced-raw.log; the independent initial policy run is phase2-g12-final-server-policy.log.

### A16

| Test | Expected result |
|---|---|
| DERP custom upgrade rejected, WS permitted | Compatible WebSocket relay fallback works. |

- Status: PASS
- Command: `bash scripts/test-coder-derp.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-final-derp-retry.log`
- Reason: -
- Detail: The loopback audit proxy recorded custom DERP upgrades rejected with 403 followed by WebSocket upgrades accepted with 101. Raw command/binary/exit/5 MiB/EOF cases then passed through the relay. Detailed request ledger: phase2-g12-final-derp-fallback-proxy.log. Server fixture was restored afterward.

### A17

| Test | Expected result |
|---|---|
| Server forces DERP WebSockets | Initial relay setup uses the required transport. |

- Status: PASS
- Command: `bash scripts/test-coder-derp.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-final-derp-retry.log`
- Reason: -
- Detail: Native server restarted with CODER_DERP_FORCE_WEBSOCKETS=true. The fresh proxy ledger recorded WebSocket 101 upgrades and no custom DERP upgrade attempts; real raw cases passed. Detailed request ledger: phase2-g12-final-derp-forced-proxy.log. This is an executed transport check, not help output.

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

- Status: PASS
- Command: `go test -C CoderNet -race -shuffle=on -count=1 -run TestNativeDERPMapUpdatePreservesSSHStream -v`
- Evidence: `.sisyphus/evidence/phase2-g12-b-derpmap-native.log`
- Reason: -
- Detail: A real native coordinator is forwarded through WebSocket/yamux/DRPC, then an additional DERP region is injected while an SSH channel is active. The connection manager's DERPMap getter confirms application; the original channel preserves 32 ordered messages through the production Unix-socket SSH proxy. Existing usable relay nodes remain unchanged. See phase2-g12-b-derpmap-brief.md; the full Go race/shuffle suite also passes.

### A20

| Test | Expected result |
|---|---|
| Coordinator connection reset | Appropriate control reconnect; no command replay. |

- Status: PASS
- Command: `bash scripts/test-coder-control.sh reset`
- Evidence: `.sisyphus/evidence/phase2-g12-b-control-reset-tests.log`
- Reason: -
- Detail: A loopback fault proxy closes the real coordinator sockets during a live native CoderTransport session. The SDK reconnects with HTTP 101, the original SSH stream remains usable, a remote execution counter remains one, and SSH establishment count remains one. See phase2-g12-b-control-reset-proxy.log and phase2-g12-b-control-brief.md.

### A21

| Test | Expected result |
|---|---|
| Invalid/expired resume token | Retry without resume token, not a spurious login prompt. |

- Status: PASS
- Command: `bash scripts/test-coder-control.sh resume`
- Evidence: `.sisyphus/evidence/phase2-g12-b-control-resume-tests.log`
- Reason: -
- Detail: After a real coordinator reset, the proxy substitutes an invalid token in the SDK's resume-bearing handshake. The native server returns 401, then the SDK retries without the resume token and receives 101. The primary credential remains unchanged, the original SSH stream stays usable without an authentication error, and the remote counter remains one. See phase2-g12-b-control-resume-proxy.log and phase2-g12-b-control-brief.md.

### A22

| Test | Expected result |
|---|---|
| Agent restart/workspace rebuild | Existing session ends appropriately; new connection resolves the right agent. |

- Status: PASS
- Command: `bash scripts/test-coder-rebuild.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-rebuild-tests.log`
- Reason: -
- Detail: An owned native workspace is rebuilt during an active CoderTransport session. Its original output stream finishes, fresh resolution returns a replacement agent UUID, explicit old-UUID resolution is rejected, and a new transport executes on the rebuilt workspace. See phase2-g12-b-rebuild-brief.md and phase2-g12-b-rebuild-agent.log for the real rebuild evidence.

### A23

| Test | Expected result |
|---|---|
| Network change or suspend/resume | Bounded recovery or clear reconnect error; no leaked sessions. |

- Status: PASS
- Command: `DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-verified-core-iphone.log' scripts/test-core.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-verified-core-iphone.log`
- Reason: -
- Detail: The live Coder conformance suite passed suspend/resume without re-handshake and terminal close/output cleanup on both canonical devices. Typed resume-failure and dead-channel recovery tests also passed. Corresponding full UI suites are now green. This covers the suspend/resume branch, not a physical Wi-Fi/cellular transition.

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

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: OpenSSH -T over the production proxy receives exactly bytes 00 01 0A 0D 7F 80 FF from the agent, with empty stderr and status 0. Both direct and relay paths passed this non-PTY case.

### A26

| Test | Expected result |
|---|---|
| Remote command exit status/stderr | Preserved by the downstream/native SSH implementation. |

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: The raw OpenSSH case asserts stdout-marker, separate stderr-marker, and exact exit status 37 through the production translation proxy. The failing-first Go test also verifies extended data and exit-status preservation after stdin EOF. Evidence is for the raw adapter with OpenSSH as downstream, not a new app exec UI.

### A27

| Test | Expected result |
|---|---|
| Large output and transfers greater than 4 MiB | Complete streaming transfer; coordinator limits not misapplied to SSH data. |

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: Streamed 5,242,880 bytes through the live agent and proxy on direct and relay paths. Byte count and SHA-256 were independently checked against the known all-zero input; digest c036cbb7553a909f8b8877d4461924307f27ecb66cff928eeeafd569c3887e29.

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

- Status: PASS
- Command: `ruby scripts/test-coder-raw.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-raw-cancellation.log`
- Reason: -
- Detail: Non-PTY cat receives binary input and EOF, then the remote command emits trailing-output after a one-second delay. Exact combined bytes and status 0 pass through both direct and relay paths. This exposed and repaired the proxy's first-copy-completion teardown defect.

### A31

| Test | Expected result |
|---|---|
| Cancellation, stdout failure, peer EOF | Both copy directions and network/controller resources terminate. |

- Status: PASS
- Command: `bash scripts/test-coder-raw.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-a31-native-green.log`
- Reason: -
- Detail: Closing the local stdout reader now terminates an unbounded remote producer within the unchanged 15-second bound, without harness timeout cleanup. Active handle cancellation also terminates an established cat session, and bridge close removes the socket and exits cleanly. Direct and relay-only runs pass. Go regressions verify write-error and eow@openssh.com cleanup while input remains open. The compatibility-prefixed BicTerm identifier enables OpenSSH's otherwise suppressed end-of-write request; it claims no numeric OpenSSH release. See phase2-g12-a31-investigation.md for the packet-level before/after proof.

### A32

| Test | Expected result |
|---|---|
| Concurrent distinct profiles/users | No credential or peer-connection cross-contamination. |

- Status: PASS
- Command: `bash scripts/test-coder-profiles.sh`
- Evidence: `.sisyphus/evidence/phase2-g12-b-profile-native.log`
- Reason: -
- Detail: Two distinct non-administrator users each have native access to their own agent and receive 404 for the other user's agent. Two CoderTransport instances connect concurrently through the production C bridge in one process, return only their own agent-provided workspace values, and closing the first leaves the second usable. See phase2-g12-b-profiles-brief.md and phase2-g12-b-profile-tests.log. No production transport change was required.

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

- Status: PASS
- Command: `ruby scripts/audit-coder-logs.rb`
- Evidence: `.sisyphus/evidence/phase2-g12-final-log-audit.log`
- Reason: -
- Detail: The auditor scans all T12 scenario log/document artifacts, including nested logs, for actual user credentials, captured native resume tokens, fixture private-key material, and unique terminal markers exercised through live sessions. Raw/URL/base64 variants and positive/negative controls pass; private-key headers and JWT-shaped values are absent. Native bridge diagnostics are captured and exclude terminal markers. The exact file/hash manifest is phase2-g12-final-log-audit.json; scope and limitations are documented in phase2-g12-final-acceptance-brief.md.
