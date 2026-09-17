# Device Sandbox: What iOS Allows vs Denies on a Physical Device

## Why this doc exists

The herdr embed failed to start on a physical iPad with `error 4: start: Operation not permitted`
because the client's first start op calls `libc::openpty`, and the app sandbox denies the pty
device-node opens. Every simulator test passed because the simulator does not enforce the app
sandbox profile. Never trust the simulator for sandbox-sensitive behavior.

## Capability matrix

Verified 2026-09-17 by `BicTermTests/Device/SandboxCapabilityProbeTests.swift` (record-only,
16 `PROBE:` lines per run). Device: iPad Pro 13-inch (M5), iOS 26. Simulator: iPhone 17 Pro.
Evidence: `.sisyphus/evidence/device-probe.log` (device) and `.sisyphus/evidence/device-probe-sim.log`.

| Operation | Device | Simulator |
|-----------|--------|-----------|
| `openpty` | fail EPERM=1 (Operation not permitted) | ok |
| `open("/dev/ptmx", O_RDWR)` | fail EPERM=1 (Operation not permitted) | ok |
| `socketpair(AF_UNIX, SOCK_STREAM)` | ok | ok |
| `fcntl(fd, F_SETFL, O_NONBLOCK)` | ok | ok |
| `dup2(fds[0], freeFd)` | ok | ok |
| `ioctl(fd, TIOCSWINSZ)` on a socket fd | fail ENOTSUP=102 (Operation not supported on socket) | fail ENOTSUP=102 |
| `createFile` container home root | fail | ok |
| `createFile` container `tmp/`, `Documents/`, `Library/` | ok | ok |
| POSIX `open(O_CREAT\|O_WRONLY)` in container home root | fail EPERM=1 | ok |
| POSIX `open(O_CREAT\|O_WRONLY)` in real `/tmp` | fail EPERM=1 | ok |

Environment facts (device):

- `NSHomeDirectory()` = `/var/mobile/Containers/Data/Application/<UUID>`
- `getenv("HOME")` = `/private/var/mobile/Containers/Data/Application/<UUID>` (note the `/private` prefix)
- `getuid()` = 501
- `getpwuid(501).pw_dir` = `/var/mobile` — OUTSIDE the data container
- Simulator: uid 501, home is the host container path, and `getpwuid(501)` has no entry (`pw_dir` null)

Notes:

- Darwin returns ENOTSUP=102 for TIOCSWINSZ on sockets, not ENOTTY=25. This bites on BOTH platforms,
  so it is not a sandbox issue; it is a property of socket fds.
- `isatty()` is false on socketpair fds.

## Design rules

- NEVER use `openpty`/`forkpty`/`/dev/ptmx` or any device node in app or vendored code. Denied on
  device, and no entitlement exists. Use `socketpair` for in-process terminal I/O.
- Never assume an fd is a tty: `isatty()` is false on socketpairs; `TIOCSWINSZ`/ioctl terminal
  control fails ENOTSUP. Geometry and resize must ride an explicit protocol message.
- Writable container locations ONLY: `tmp/`, `Documents/`, `Library/` (and their subdirs). The
  container home root and the real `/tmp` are EPERM. Keep Unix sockets under `tmp/` (the
  `sun_path` 104-byte limit forces relative paths via the cwd pin).
- Never resolve `$HOME` via `getpwuid` — it escapes the container (`/var/mobile`). Vendored code
  must get `XDG_CONFIG_HOME`/`XDG_STATE_HOME` overrides; see
  `HerdrEmbedRuntime.prepareClientEnvironment`.
- Never log secrets; Keychain / Secure Enclave only (unchanged rule, restated here for context).

## How to re-probe

Suite: `BicTermTests/Device/SandboxCapabilityProbeTests.swift` (record-only; prints `PROBE:` lines
to stdout, asserts only that each probe executed — unexpected values ARE the evidence).

Simulator:

```bash
source scripts/env-local-caches.sh
xcodebuild -project BicTerm.xcodeproj -scheme BicTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build-artifacts/DerivedData/sandbox-probe \
  -only-testing:BicTermTests/SandboxCapabilityProbeTests test | tee .sisyphus/evidence/device-probe-sim.log
```

Device (connected physical device):

```bash
xcodebuild -project BicTerm.xcodeproj -scheme BicTerm \
  -destination 'platform=iOS,name=<device name>' \
  -derivedDataPath .build-artifacts/DerivedData/sandbox-probe \
  -only-testing:BicTermTests/SandboxCapabilityProbeTests \
  DEVELOPMENT_TEAM=BALVL8YD22 -allowProvisioningUpdates test | tee .sisyphus/evidence/device-probe.log
```

Gotchas:

- `DEVELOPMENT_TEAM=BALVL8YD22` must be passed on the command line for device runs: `project.yml`
  sets the team only on the app target; the test targets carry no team and
  `-allowProvisioningUpdates` cannot invent one.
- Keep DerivedData repo-local under `.build-artifacts/DerivedData/` (containment rule).
- Extract the evidence with `grep 'PROBE:' <log>`.
- The real-`/tmp` POSIX probe creates a transient host file when run on the SIMULATOR (unlinked in
  the same probe); on device nothing is created (EPERM).

## Evidence and mitigation pointers

- Probe evidence logs (2026-09-17): `.sisyphus/evidence/device-probe.log`,
  `.sisyphus/evidence/device-probe-sim.log`.
- `e1d280a` — relocate embed transport dir under container `tmp/`.
- `38e1542` — tear down transport when embed session start fails + XDG env hardening
  (`XDG_CONFIG_HOME` into App Support via `prepareClientEnvironment`).
- Socketpair embed redesign: the living record is the embed patch ledger
  `Vendor/herdr/EMBED-PATCHES.md`.
