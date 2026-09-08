# BicTerm security decisions

## Ordinary SSH profiles: TOFU host-key trust

Every ordinary (`type == .ssh`) connection performs trust-on-first-use host-key
verification through `HostKeyVerifier(store:)` (trust policy `.tofu`):

- First contact: the presented key is persisted as `.firstSeen` and the connect
  fails with the typed `TransportError.requiresTrust`; the UI prompts, and only
  an explicit user approval calls `trust(...)`.
- Key change on a trusted record: hard reject with
  `TransportError.hostKeyChanged` — no connect, ever.
- The user-auth delegate is chosen strictly by the connection's declared
  method (key or password, never both), and credential resolution failures
  surface as `TransportError.authenticationFailed` before any dial.

Nothing in the Coder machinery below weakens this path. The two policies are
enum-separated at the type level and the normal SSH profile factory
(`SSHSessionTransportFactory`) contains no reference to the Coder trust
machinery (kept honest by `CoderTrustPolicyTests`).

## Coder workspace sessions: the tailnet transport is the boundary

Reference: `CODER_WORKSPACE_SSH_PROTOCOL_SPEC.md` §10.5 and §11.1–11.4.

A Coder workspace agent runs a built-in SSH server with `NoClientAuth: true`.
The stock Coder SDK policy is: create the SSH client connection **without** an
SSH password/private-key configuration and skip independent SSH host-key
checking. Authorization has already happened through Coder's authenticated
network setup (WireGuard between client and agent; the coordinator introducing
peer keys, including over DERP relays).

BicTerm mirrors that stock policy deliberately (the "coder tunnel trust
policy"):

- `HostKeyVerifier.coderTunnel()` (policy `.coderTunnelTrust`) accepts the
  agent's host key unconditionally. Agent host keys are ephemeral and rotate
  on rebuilds; pinning them would produce false rejections. The policy never
  reads from or writes to the persistent TOFU store — acceptance leaves no
  trace, and `trust(...)` is a no-op under it.
- `SSHTransport.connect(unixSocketPath:cols:rows:)` offers the RFC 4252
  `none` method exactly once (`NoClientUserAuthenticationDelegate`), under the
  fixed username `coder` — per spec §11.4 an example username, never a
  privilege instruction. The vendored NIOSSH fork supports `Offer.none`, so
  **no dummy-password fallback exists anywhere**. A server that rejects `none`
  gets the typed `TransportError.authenticationFailed`, final — coder sessions
  never fall back to credentials.
- A TOFU-mode transport pointed at a coder-posture server still gates the
  unseen host key (typed `TransportError.requiresTrust`) — the UDS dial and
  the `none` offer never smuggle a server past the ordinary trust model.

### What this does and does not claim

- This arrangement says: whoever can drive the Coder transport can reach the
  workspace shell. The authenticated, authorized tailnet path **is** the
  access boundary.
- It does **not** claim protection against a malicious Coder control plane
  (spec §10.5 says not to make that claim while following the SDK's stock
  policy). Independent host-key pinning remains a possible additional policy,
  per §11.4, and would require a documented key-rotation story.
- The trust exception is confined to coder-tunnel sessions. It is never
  selected for ordinary SSH profiles, never applied to the Coder HTTPS/REST
  connection, and never applied under a `Host *`-style wildcard rule.

## Per-session UDS endpoint contract

The bridge that fronts a coder session (Go bridge in production; the test
double in `UDSTransportTests`; `Fixtures/bin/uds-forward.py` for the fixture)
owns the socket endpoint. `SSHTransport` only ever **dials** it. Invariants:

1. The socket path is per-session random: `coder-ssh-<uuid>.sock`.
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

## Build isolation: AGPL tunnel core vs App Store flavor

Phase 2, task 7 (2026-09-07). BicTerm builds in two flavors from one Xcode
project (`project.yml`, xcodegen):

| | Default flavor | AppStore flavor |
|---|---|---|
| Scheme | `BicTerm` | `BicTerm-AppStore` |
| Configurations | `Debug`, `Release` | `AppStore-Debug`, `AppStore-Release` |
| `CODER_TUNNEL` Swift flag | set on app + test targets | absent everywhere |
| `CoderTunnel` target | built and statically linked | never built (not in the scheme) |
| Coder tailnet tunnel | shipped (AGPL-3.0 Go core) | absent; coder connections use direct SSH |

### Why a framework target and not a library import

`CoderNet.xcframework` statically fuses AGPL-3.0-licensed code
(coder/coder v2.36.4 `codersdk`/`workspacesdk` plus the coder fork graph).
The boundary for that code is exactly one framework target:

- `CoderTunnel` (Xcode target, `MACH_O_TYPE=staticlib`) — contains
  `CoderNetTunnel: CoderTunneling`, the only Swift code that imports the
  `CoderNet` Clang module. It links the xcframework's per-slice
  `CoderNet.a` and nothing else foreign.
- `BicTermCore` — defines `CoderTunneling` (pure Swift, no imports beyond
  Foundation) and carries `ProtocolDescriptor.supportsTailnetTunnel`,
  injected at registration from the build flavor. BicTermCore itself stays
  permissive-license clean and builds identically in both flavors.
- The app links `CoderTunnel` only when compiled for `Debug`/`Release`
  (per-config `-framework CoderTunnel` + `-lresolv`) and reads the flavor
  through `BuildFlavor.coderTailnetTunnelSupported` (`#if CODER_TUNNEL`).

### Three-layer audit (run per release, both flavors)

Symbol stripping could hide a leak, so all three layers are mandatory:

1. **Build-system proof** — the AppStore scheme's build action never lists
   `CoderTunnel` (`xcodebuild -list` scheme matrix + the AppStore build log
   contains zero `CoderTunnel` task lines).
2. **Bundle proof** — the AppStore `.app` tree contains no
   `CoderTunnel`/`CoderNet` framework or dylib, and `otool -L` on the app
   binary shows no CoderTunnel load command.
3. **Symbol sweep** — `strings` over every Mach-O file in the AppStore
   bundle finds zero `CoderNet`/`workspacesdk` matches; the default-flavor
   build shows positive matches (proving the sweep detects the code when
   present).

Logs: `.sisyphus/evidence/phase2-g7-appstore-audit.log` and
`.sisyphus/evidence/phase2-g7-default-audit.log`.

### Invariants that keep the flavors honest

- No runtime download of the tunnel: it is build-time linked or absent.
- No user-facing tunnel claim in the AppStore flavor: the capability is
  compile-gated, not UI-hidden (`BuildFlavorTests` asserts both directions
  against the `AppServices` registered descriptor).
- `-force_load` is deliberately NOT used on the merged static archive: Xcode
  merges the SwiftPM product objects into `CoderTunnel.a` for a staticlib
  framework, and wholesale extraction double-defines them. On-demand
  archive extraction keeps those members dormant so each module resolves
  exactly once; the app's metatype reference to `CoderNetTunnel.self`
  provides the demand edge.
