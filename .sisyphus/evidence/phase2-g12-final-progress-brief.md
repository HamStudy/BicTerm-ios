# T12 protocol acceptance checkpoint — INCOMPLETE

Latest status: **PASS=29, FAIL=2, NOT-LOCAL=3**. Batch A closed A31;
Batch B has closed A02-A12, A20-A22, and A32. The checkpoint narrative below
preserves the earlier 13/18/3 state. A31 evidence is in
`phase2-g12-a31-investigation.md`; native authentication/permission evidence
is in `phase2-g12-b-auth-native-green.log`, `phase2-g12-b-auth-audit.log`,
and `phase2-g12-b-permission.log`.

Agent-selection slice: `bash scripts/test-coder-selection.sh` provisions two
agents, snapshots identities, rebuilds, then runs four native Core tests.
`phase2-g12-b-selection-behavior-red.log` proves explicit options were ignored
before the repair; `phase2-g12-b-selection-acceptance.log` is green afterward.
Before/after public identities are in `...-selection-previous.log` and
`...-selection-current.log`; the full wrapper is `...-selection-wrapper-final.log`.
The existing resolver suite remains green in `...-resolver-regression.log`.

Start slice: `bash scripts/test-coder-start.sh` exercises real explicit start
and accepted-response loss via the app-side starter. The ledger asserts one
201 POST and an authoritative recheck with no second mutation. Evidence:
`phase2-g12-b-start-native.log`, `phase2-g12-b-start-agent-ledger.log`.
`phase2-g12-b-start-disabled.log` proves the disabled native path sends GETs only.

Startup slice: `bash scripts/test-coder-startup.sh` provisions blocking,
nonblocking, error and timeout scripts and executes four Core tests.
`bash scripts/test-coder-startup-policy.sh` independently exercises the two
held-script policies through explicit app-side starts. Evidence:
`phase2-g12-b-startup-tests.log`, `phase2-g12-b-auto-final.log`, with red runs
in `...-startup-red.log` and `...-auto-red.log`.

Lifecycle-action slice: `bash scripts/test-coder-actions.sh` exercises real
dormancy and required-parameter mismatch. Both attempts issue GETs only,
return action instructions, and preserve workspace detail. The native red run
proved that a start POST clears dormancy; a fresh service-side preflight now
refuses it. Evidence and regression results: `phase2-g12-b-actions-brief.md`.

Profile-isolation slice: `bash scripts/test-coder-profiles.sh` prepares two
non-administrator users with mutually denied cross-agent access, then connects
both concurrently in one Swift process. Each stream returns its own remote
workspace value, and the second survives closing the first. Evidence:
`phase2-g12-b-profiles-brief.md` and `phase2-g12-b-profile-native.log`.

Active-session rebuild: `bash scripts/test-coder-rebuild.sh` proves the old
stream ends during a real rebuild, the old UUID is rejected, and a fresh
transport executes on the replacement. Evidence: `phase2-g12-b-rebuild-brief.md`.

Control recovery: `bash scripts/test-coder-control.sh reset` and `resume`
exercise real coordinator resets and invalid resume-token rejection. The SDK
reconnects; the invalid-token retry omits that token. The original stream stays
usable with its execution counter and SSH establishment count both unchanged
at one. Evidence: `phase2-g12-b-control-brief.md`.

Remaining: A19, A34.

This checkpoints executed native evidence, not phase approval. Matrix:
**PASS=13, FAIL=18, NOT-LOCAL=3**. Structural validation passes; `--gate`
correctly rejects the remaining FAIL rows. UI acceptance is separately
complete in `phase2-g12-ui-acceptance.md`; it is not rerun or modified here.

## Executed and accepted rows

- A01: OpenSSH command execution through the production CoderNet UDS proxy.
- A13/A14: working direct and endpoint-blocked relay-only sessions, with
  actual networkPathChanged observations (not synthetic path events).
- A15: server disable-direct respected by a client with relay_only=false.
- A16: custom DERP upgrade rejected with HTTP 403, followed by WebSocket 101
  fallback and working SSH traffic, captured by the loopback proxy ledger.
- A17: server-forced WebSockets use WebSocket 101 without an initial custom
  DERP upgrade, with working SSH traffic.
- A23/A24: live simulator suspend/resume, cleanup and remote terminal resize.
- A25/A26: byte-exact non-PTY binary output, distinct stderr and exit status 37.
- A27: 5,242,880-byte streaming output, independently checked byte count and
  SHA-256 c036cbb7553a909f8b8877d4461924307f27ecb66cff928eeeafd569c3887e29.
- A30: stdin EOF followed by delayed trailing output without truncation.
- A33: deterministic usage-heartbeat lifecycle tests.

The raw harness records individual case outcomes. Its A31 stdout-failure
case still fails; other passing cases do not imply aggregate suite success.

## Repair checkpoint

`f5f619a` pairs `CoderNet/sshproxy.go` with `sshproxy_eof_test.go` and
red/green Go evidence. Before the repair, OpenSSH authenticated successfully
but received channel close without an exit status when stdin ended. The
in-process regression also lost stdout and stderr. This refuted wrong-user
and failed-handshake explanations and confirmed premature first-copy teardown.

The repair drains stdout, extended-data stderr and upstream requests before
teardown, then joins inbound relays. The focused test and shuffled race-enabled
Go suite pass. Temporary SSH DEBUG3 tracing was removed from the harness;
the original diagnostic trace is retained as historical evidence.

## Remaining FAIL rows

A02 invalid/expired user token; A03 authorization-hidden 404; A04 ambiguity;
A05 exact name/UUID; A06 old-build UUID; A07 start disabled; A08 explicit start;
A09 lost start response; A10 dormancy/parameter mismatch; A11 startup script
blocking policy; A12 startup failure/timeout; A19 dynamic DERP map; A20
coordinator reset; A21 resume-token expiry; A22 restart/rebuild; A31 fatal
output/cancellation cleanup; A32 concurrent distinct profiles; A34 complete
four-category sentinel log audit.

A31 currently observes that closing OpenSSH's stdout reader while an unbounded
producer runs does not terminate the child within 15 seconds. The harness
records failure and terminates its own process group; active bridge-handle
cancellation independently passes. The failed case must be root-caused,
not reclassified or hidden. A34's existing scan covers only the actual user
token and selected terminal markers, not the complete required four categories.

## NOT-LOCAL and optional live scope

- A18: needs-private-CA; optional approved private-CA/reverse-proxy validation.
- A28/A29: scope-explained, permanent v1 session-channel guardrail exclusions.
  They are not optional live-pass items.

No additional environment limitation is invented. Herdr remains blocked.

## Exact commands

Run from `/Users/richard/code/BicTerm`; all controllable artifacts stay local.

```sh
source scripts/env-local-caches.sh
go -C CoderNet test -race -run TestSSHProxyDrainsOutputAndStatusAfterStdinEOF -count=1 -timeout=60s
go -C CoderNet test -race -shuffle=on -count=1 -v -timeout=120s ./...
bash scripts/test-coder-raw.sh
ruby scripts/test-coder-raw.rb
CODER_GATE_RELAY_ONLY=1 ruby scripts/test-coder-raw.rb
bash scripts/test-coder-derp.sh
bash scripts/build-coder-net.sh
ruby scripts/verify-coder-matrix.rb
ruby scripts/test-coder-matrix.rb --seed 1
ruby scripts/verify-coder-matrix.rb --gate
```

`test-coder-raw.sh` builds the current Go source as a host C archive and links
the C fixture with explicit generated-header paths. The Ruby harness records
the complete fixed OpenSSH arguments and each remote command. Credentials
arrive from the private fixture env file, not command-line arguments.

`test-coder-derp.sh` records proxy upgrade/status ledgers, restarts the native
server with explicit disable-direct/force-WebSocket settings, drives the raw
client through port 7081, and restores the default fixture on exit. The first
attempt incorrectly targeted 7080, bypassing observation; the retry used 7081
and passed. Cleanup recognizes expected SIGTERM status so restoration executes.

## Evidence index

Paths below are relative to `.sisyphus/evidence/`; all `phase2-g12-final-*`
artifacts are included in this checkpoint, including failed attempts.
Raw `.log` transcripts are byte-preserved Git binary artifacts through the
narrow `.gitattributes` rule: Xcode/terminal CRs and trailing spaces are data,
not source formatting. Source, scripts and Markdown retain whitespace checks.

- `phase2-g12-final-proxy-eof-red.log`, `...-proxy-green.log`,
  `...-go-tests.log`, `...-go-vet.log`: focused failure and Go verification.
- `phase2-g12-final-raw.log`, `...-raw-probe.log`, `...-raw-ssh-debug.log`:
  original failure and diagnostic SSH trace.
- `phase2-g12-final-raw-green.log`, `...-raw-direct.log`, `...-raw-relay.log`,
  `...-raw-relay-current.log`, `...-raw-cancellation.log`: raw behavior cases.
- `phase2-g12-final-raw-bridge.log`, `...-raw-bridge-direct.log`,
  `...-raw-bridge-relay.log`: bridge diagnostics; later runs replace per-mode
  logs, while their case-result logs retain the observed outcomes.
- `phase2-g12-final-server-policy.log`: independent server-policy exercise.
- `phase2-g12-final-derp.log`, `...-derp-retry.log`: initial attempt and
  successful fallback/forced-WebSocket receipt.
- `phase2-g12-final-derp-{fallback,forced}-{fixture,proxy,raw}.log`: provisioning,
  actual upgrade ledgers and raw SSH assertions for each mode.
- `phase2-g12-final-derp-restore.log`: default native fixture restoration.
- `phase2-g12-final-xcframework.log`: rebuilt iOS/device and simulator archive.
- `phase2-g12-final-{new-window-red,new-window-red2,new-window-green,port-probe,
  port-export,port-keyboard,agent-export,agent-green,trust-clean,full-iphone,
  full-ipad,ConnectionEditorUITests,PasswordAuthUITests,CoderAgentPickerUITests}.log`:
  earlier UI evidence retained without changes to the completed UI work.

The root debug journal's durable findings are transferred here and to the
notepads. Temporary selection-menu instrumentation and SSH DEBUG3 mode are
removed; the root journal is deleted. Large xcresults and binaries remain
repository-local ignored build artifacts. No protected files are included.
