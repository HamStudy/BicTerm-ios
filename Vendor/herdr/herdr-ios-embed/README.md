# herdr-ios-embed

In-process C ABI that runs the REAL herdr TUI client against a host-owned
pty (plan `.omo/plans/herdr-embed.md`, task 3). `herdr_embed_start` opens a
pty pair, spawns a thread that dup2s the slave onto fds 0/1/2 and runs
`herdr::run_client()` there, and keeps the master for the host: input via
`herdr_embed_write_input`, rendered output via the cancellable blocking
`herdr_embed_read_output`, resizes via `herdr_embed_set_winsize`
(TIOCSWINSZ + SIGWINCH), teardown via `herdr_embed_stop`. The C surface is
declared in `include/HerdrEmbed.h` (cbindgen-generated, never hand-edited).

## Build flow

The crate depends on the PATCHED herdr working copy that
`scripts/herdr-embed-prepare.sh` materializes at
`../../../.build-artifacts/herdr-embed` (T1's patch series + T2's real
`libghostty-vt.a`). Without that working copy the path dependency fails —
run the prepare script first. The Vendor/herdr workspace excludes this
directory so the stock herdr-ios-ffi builds never require it.

```sh
scripts/herdr-embed-prepare.sh   # patches + real .a + iOS build proof (both
                                 # feature variants) + cbindgen drift check
# host harness tests (real herdr server fixture, one test per process):
HERDR_LIBGHOSTTY_VT_PREBUILT="$PWD/.build-artifacts/herdr-vt/aarch64-macos" \
  cargo test --test headless_frame --test headless_detach --test headless_resize
cargo test --test lifecycle      # shim lifecycle + fd hygiene (no server)
```

The host tests need a macOS-host `libghostty-vt.a`
(`HERDR_VT_TARGETS=aarch64-macos scripts/herdr-vt-build.sh`) and the pinned
prebuilt server (`scripts/herdr-server-fetch.sh`). Builds must run with the
repo-local `RUSTUP_HOME`/`CARGO_HOME` (see `scripts/env-local-caches.sh`);
the crate pins toolchain 1.96.1 to match the working copy.

## Process-global contract (the honest list)

* **stdio** — dup2 makes the pty slave the process-wide stdin/stdout/stderr.
  On iOS those point at `/dev/null`; the originals are saved and restored by
  `herdr_embed_stop`. crossterm reads input from fd 0 and writes output to
  fd 1/2, so only ONE embedded client TUI may run at a time process-wide;
  multi-machine herds ride one client through its endpoint catalog.
* **SIGWINCH** — this crate never installs a SIGWINCH handler. The embedded
  client owns the process-wide handler (herdr's own sigaction flag consumed
  by its 100ms resize poll). `set_winsize` applies TIOCSWINSZ on the master
  and raises SIGWINCH via `kill(getpid(), ...)`: whichever unblocked thread
  catches it runs that handler. `start` blocks SIGWINCH on the calling
  (host) thread before spawning — every thread created afterwards inherits
  the block — and the embed thread unblocks it in itself, making the embed
  thread the preferred recipient. Host rule: Swift must not install its own
  SIGWINCH handler (use view-layout callbacks); a pre-existing thread that
  catches the signal merely runs the client's idempotent flag-setting
  handler.
* **SIGTERM** — `stop` raises SIGTERM to trigger the client's clean quit
  (its ctrlc handler sets should_quit). The crate installs its own
  flag-setting SIGTERM handler at start as the safety net for kills that
  land before the client boots. Note: only the FIRST client in a process
  can install the ctrlc handler (later installs fail with "already
  registered"), so the detach key sequence (`herdr_embed_config.detach_input`,
  default ctrl+b q) is the primary quit path for later instances.
* **env** — `HERDR_CLIENT_SOCKET_PATH` is process-global; herdr resolves it
  once at the top of `run_client`. Starts serialize through a global gate:
  the embed thread re-asserts its socket path (and clears
  `HERDR_SOCKET_PATH`, which would otherwise win) immediately before
  `run_client`. Start the next instance only after observing the previous
  instance's first output.
* **thread safety** — unlike the herdr-ios-ffi client this instance IS safe
  for concurrent `read_output` / `write_input` / `set_winsize` /
  `is_running` calls from distinct threads (a blocking read must coexist
  with UI-thread writes). `herdr_embed_stop` consumes the handle: no other
  call may race it, and the handle is dead afterwards (a
  `HERDR_EMBED_CODE_STOP_TIMEOUT` result leaves it retryable).
* **teardown order** — stop closes the pty master before neutering the
  client's stdio onto /dev/null: closing the master wakes threads blocked
  reading it, and a dup2 over an fd another thread is blocked reading
  deadlocks on Darwin. The neuter matters because the client maps an EIO
  write to an error path that calls `process::exit(1)` — fatal in-process.
* **diagnostics** — set `HERDR_EMBED_STDERR_LOG=<path>` to route the
  client's stderr to a file instead of the pty (on iOS the process stderr
  is /dev/null anyway); final client error messages survive teardown there.
