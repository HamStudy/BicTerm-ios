# Fixtures Agent Knowledge Base

## OVERVIEW
Loopback-only (127.0.0.1) test fixtures for BicTerm's SSH transport, ProxyJump, and agent-forwarding tests; no Docker, no containers, nothing touches the real network or `~/.ssh`.

## STRUCTURE
```
Fixtures/
├── sshd/    # sshd config templates: hop1_config, hop1_config.alt, hop2_config, host_keys/, host_key_alt/
├── bin/     # uds-forward.py (Python 3 stdlib-only UDS→TCP forwarder)
├── keys/    # ephemeral test keys, bicterm-fixture-* (encrypted one's passphrase: testpass)
├── agent/   # agent_client.py: ssh-agent wire-protocol client for T8/T14
├── herdr/   # mock-herdr, mock-bridge.py, fake-herdr-status, gen/, golden/
└── run/     # runtime state (pids, logs, rendered ssh wrapper); gitignored
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Fixture lifecycle | `scripts/fixtures-up.sh` / `fixtures-down.sh` | idempotent, self-checks, non-zero on failure |
| hop-1 (bastion) | `sshd/hop1_config` | port 12222, key-only auth |
| hop-2 (final) | `sshd/hop2_config` | port 12223, ed25519 key only |
| Changed-host-key test (T7) | `sshd/hop1_config.alt` + `host_key_alt/` | `HOP1_ALT_KEY=1 fixtures-up.sh`; active config in `run/hop1.active_config` |
| UDS dial tests (T8) | `bin/uds-forward.py` | bridges `run/sshd-uds.sock` to 127.0.0.1:12222 |
| Agent protocol torture | `agent/agent_client.py` | list / sign / sign-raw / flood |
| Provenance logs (T9) | `run/hopN.log` | sshd runs `LogLevel DEBUG3 -E` |

## CONVENTIONS
- One directory per fixture block; each new block gets a pidfile `run/<name>.pid`, log `run/<name>.log`, a port-wait and a self-check in `fixtures-up.sh`, and a README section.
- sshd configs use absolute paths; the committed configs carry the neutral placeholder prefix `/Users/localdev/`, and `fixtures-up.sh` rewrites it to the current checkout via ANCHORED sed each run (the working-tree configs therefore show as modified after a run; never commit the rewritten paths). The trailing slash in the anchor (`/Users/localdev/code/BicTerm/`) is load-bearing: un-anchored, `/BicTerm/` matches `/BicTerm-ios/` and every run appends another `-ios` (`BicTerm-ios-ios-ios` corruption).
- Configs are edited in place, not templated into `run/`; keys are committed (deterministic for T3 parser golden tests) and regenerated if deleted.
- Both sshds: `PasswordAuthentication no`, `AllowTcpForwarding yes` (ProxyJump needs it), `AllowAgentForwarding yes`, `StrictModes no`, `UsePAM no` (unprivileged sshd on macOS).
- `fixtures-up.sh` generates `run/bin/ssh`, a wrapper translating `-J` into an explicit `ProxyCommand`: the implicit ProxyJump child re-execs `/usr/bin/ssh` and inherits neither `-o` flags nor `$HOME`, so project-local known_hosts/identity would be unreachable otherwise.
- macOS sshd unblocks after the FIRST TCP connect, so `nc -z` port-waits are reliable.

## ANTI-PATTERNS
- Never commit anything under `run/` (pids, logs, `bin/ssh` wrapper, `hop1.active_config`).
- Never hardcode a new absolute repo path into configs expecting it to stay valid; the sed substitution handles checkout moves.
- Never write to `~/.ssh` from fixture tooling; use `-o UserKnownHostsFile=/dev/null` style flags or the wrapper.
- Fixture keys are throwaway test material only; never reuse real keys or credentials here.
- No Docker or containers anywhere in the fixture flow; keep every bound port loopback-only.

## NOTES
- `fixtures-down.sh` kills daemons from the `run/pids` manifest and verifies ports closed.
- Two-hop CLI checks by hand need `PATH="$PWD/Fixtures/run/bin:$PATH"` (see README).
- RSA fixture key (`bicterm-fixture-rsa3072`) is authorized NOWHERE; it exists for T3 RSA-rejection parsing.
