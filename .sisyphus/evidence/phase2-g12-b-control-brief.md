# A20/A21 native coordinator recovery

Commands:

- `bash scripts/test-coder-control.sh reset`
- `bash scripts/test-coder-control.sh resume`

A loopback TCP fault proxy forwards the actual Coder REST and coordinator
traffic. It closes only coordinator sockets after a live remote command has
incremented an execution counter. The SSH stream is not replaced by a fake.

## Coordinator reset

`phase2-g12-b-control-reset-proxy.log` records an initial HTTP 101, the
coordinator socket reset, and a subsequent HTTP 101 with a resume token.
`phase2-g12-b-control-reset-tests.log` records one passing native Swift test.
The original remote counter remains one and SSH establishment count remains
one after recovery; the original stream remains usable.

## Invalid resume token

`phase2-g12-b-control-resume-proxy.log` records:

1. Initial coordinator handshake: no resume token, HTTP 101.
2. Coordinator reset.
3. SDK reconnect carrying its resume token: the proxy substitutes an invalid
   token, and the real server rejects it with HTTP 401.
4. SDK retry omitting the resume token: HTTP 101.

The primary session credential is unchanged. The live Swift connection stays
usable without returning an authentication error, the remote counter remains
one, and no second SSH establishment occurs. The native test passes in
`phase2-g12-b-control-resume-tests.log`.

The proxy records only token presence, injection status, and response codes;
it never records request headers or token values. Non-upgraded HTTP exchanges
are closed so every handshake is parsed and counted, including retries after
HTTP 401. Initial proxy instrumentation missed a retry on a reused connection;
requesting connection close fixed the harness, not production transport code.

## Verification and scope

Both native modes passed after the proxy connection-handling correction.
Ruby and shell syntax checks and git whitespace checks passed. SourceKit
could not resolve CoderNet/XCTest; Xcode builds compiled and ran the tests.
Ruby and shell LSP servers are unavailable and were not installed.

Final full-suite runs must start the fault proxy alongside the control test.
The wrapper arranges that state for focused runs. A19 and A34 remain open;
this is acceptance-row evidence, not phase approval.
