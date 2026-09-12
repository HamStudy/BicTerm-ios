# BicTerm security decisions

## Ordinary SSH profiles: TOFU host-key trust

Every connection performs trust-on-first-use host-key verification through
`HostKeyVerifier(store:)`:

- First contact: the presented key is persisted as `.firstSeen` and the connect
  fails with the typed `TransportError.requiresTrust`; the UI prompts, and only
  an explicit user approval calls `trust(...)`.
- Key change on a trusted record: hard reject with
  `TransportError.hostKeyChanged` — no connect, ever.
- The user-auth delegate is chosen strictly by the connection's declared
  method (key or password, never both), and credential resolution failures
  surface as `TransportError.authenticationFailed` before any dial.

## Per-session UDS endpoint contract

A unix-domain-socket bridge fronting an SSH session (the test double in
`UDSTransportTests`; `Fixtures/bin/uds-forward.py` for the fixture) owns the
socket endpoint. `SSHTransport` only ever **dials** it. Invariants:

1. The socket path is per-session random: `bicterm-uds-<uuid>.sock`.
2. The bound socket carries permissions `0600` from creation.
3. A stale leftover at the path (crashed previous session) is unlinked before
   bind; a live listener at the path is never replaced.
4. Session close/cancel removes the socket.
5. A closed session's socket is never reconnected or rebound by another
   session (fresh UUID per session).
6. Concurrent sessions always hold distinct sockets.

Platform constraint: `sockaddr_un.sun_path` holds 104 bytes on Darwin. On iOS
this rules out the app-container `tmp` directory directly (its absolute path
approaches the limit); the bridge must bind under a short app-controlled
directory. Tests therefore bind under the repo-local `Fixtures/run/`
(gitignored) — the invariant is the per-session name pattern, not the
sandbox-tmp literal.

## Transport write/test boundaries

- Simulator unit tests reach fixture daemons on host loopback
  (`127.0.0.1:12222/12223`) and the host-bound UDS at
  `Fixtures/run/sshd-uds.sock`; the simulator shares the host kernel and
  filesystem for these paths.
- The only permitted fixture mutation from tests is append+restore of
  hop1 `authorized_keys` (see `SSHTestFixture.withHop1AuthorizedKeyAdded`).
- All agent-controlled outputs — DerivedData, evidence logs, socket files,
  scratch — stay repo-local (`.build-artifacts/`, `.sisyphus/evidence/`,
  `Fixtures/run/`).
