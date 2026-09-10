# Embedded protocol and client state

Baseline: Herdr v0.9.0, `b99002ac99b09e00b4ca692436cb15a6b0d676f1`.

## Crates

- **herdr-protocol**: complete frozen client/server wire enums, semantic input,
  clipboard envelopes, snapshots/surfaces/patches, stable endpoint JSON carriers,
  and the upstream length-prefixed bincode codec.
- **herdr-client-core**: validated in-memory endpoint catalog, independent
  supervisors and health, bounded outbound queues, qualified projection state,
  atomic patches, semantic pane input, and the complete transactional activation
  state machine through the presentation-ready fence.

No server, PTY execution, Ghostty, desktop rendering backend, local-socket bridge,
SSH subprocess, installer, updater, or plugin runtime is compiled into these
crates. Some frozen wire records describe desktop operations; preserving their
layout does not mean executing them is supported.

## Caller contract

The core is synchronous state machinery, not a network runtime. Use one instance
per viewer/scene and serialize calls to it. Add viewer identity when keeping
qualified targets in storage shared across instances.

1. Decode/save profiles through `EndpointCatalog`; retain SSH credentials and
   trust decisions in the host application's existing credential layer.
2. Use `EndpointSupervisors::poll_due` with a concurrency limit. Execute each
   returned `ConnectionAttempt` independently. Discard results when
   `record_status` rejects their generation; cancel retired attempts at the
   transport boundary.
3. Negotiate each connection with `PendingHandshake`, an inactive
   `EndpointClientHello`, and `direct_graphics = false`. The remote deadline is
   60 seconds and admission requires surface interest, presentation fence,
   surface-set method and health support. No private-handshake fallback exists.
4. Insert the admitted connection into `EndpointRegistry`. An `OutboundQueue`
   clone can serve as its `EndpointTransport`; drain complete frames and write
   them in order with backpressure. Queue acceptance is **not** a network-write
   acknowledgment. Propagate write failure with `registry.fail`; do not replay
   buffered input after reconnect. Explicit detach/drain/close belongs to the
   caller; Drop is bounded best-effort cleanup, not a reliable detach flush.
5. Feed only stdout protocol bytes to `herdr_protocol::read_message` using a
   bounded reader/frame limit. A reader must preserve partial reads; a truncated
   frame is an error, not a resumable decoder object. Keep stderr separate.
6. Check `registry.accepts` before processing a callback, call `received` on
   accepted traffic, and mark the initial authoritative snapshot ready. Drive
   `tick_health` from the caller's foreground scheduler. Route metadata through
   `ClientShellState::receive_snapshot`; disconnected metadata may remain stale
   and must not be offered as an actionable pane.
7. Start a `PendingEndpointActivation` with a unique per-instance serial and
   current geometry. Settle source keys/gestures in the native input layer first.
   Feed its correlated responses, snapshots, surfaces and presentation-ready
   control. Assemble bounded response chunks before passing response bytes;
   partial chunks are not complete JSON responses. Use `complete_activation`:
   the visible frame may commit before input
   is enabled. Apply target presentation replay between those stages; do not
   discard it. Handle rollback/successors on the same serial executor before
   dispatching further input.
8. Use `send_pane_input` with a captured `QualifiedPane`. It rejects frozen,
   replaced, wrong-machine, wrong-boot and incoherent-projection targets. Do not
   bypass this with low-level `send_to`, `set_active`, or `unfreeze_input` for
   ordinary pane interaction.

Clipboard UI policy, native selection/mouse/key mapping, presentation effects,
aggregate iPad memory budgets, image decoding, foreground jitter, SSH I/O and
C ABI ownership are outside this extraction. The precise desktop-bound methods
are listed in `EXTRACTION_ESCALATION.md`. No native UI parity is claimed.

## Verification

Run from the BicTerm root:

```sh
bash Vendor/herdr/check.sh
```

The script sources repository-local caches and rustup home, checks formatting,
runs both crates' tests, builds macOS/device/simulator, resolves production
licenses separately for both iOS targets, checks cargo-deny, exercises negative
license cases, and audits excluded imports. It does not regenerate golden frames.

Read `PROVENANCE.md` before distribution. In particular, cargo-deny has an
explicit **bincode unmaintained-advisory exception**, not a vulnerability fix.
License inventory is not a substitute for the application's final notices.
