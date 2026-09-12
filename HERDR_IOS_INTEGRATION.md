# Integrating Herdr into an iOS SSH Client

**Design, implementation, security, licensing, and App Store release plan**  
**Prepared:** 7 September 2026; updated 8 September 2026 for multi-machine support  
**Herdr source reviewed:** release **v0.9.0**, commit [`b99002ac99b09e00b4ca692436cb15a6b0d676f1`](https://github.com/herdrdev/herdr/commit/b99002ac99b09e00b4ca692436cb15a6b0d676f1)

**Review basis:** this update directly reviewed the **v0.9.0 tagged source**, including its multi-machine guide, machine CLI, saved-SSH transport, endpoint negotiation, activation and presentation synchronization, connection health, message routing, and license/manifest. The checked-out tag resolves to the commit above, and its Cargo manifest declares version `0.9.0`. The recommendations and implementation references target that release, not an assumed 0.8.2 implementation. This remains a design/source review, not an iOS device-tested integration.

> This is an engineering and release-readiness analysis, not legal advice. Have counsel review the final dependency inventory, trademark use, encryption classification, and store submission before release. Apple alone decides whether an app passes review.

## Executive summary

This feature is feasible for an App Store iOS app, but it should **not** be implemented by trying to run the unmodified Herdr executable on the iPad.

The right architecture is:

1. Keep each Herdr server, terminal processes, shells, agents, and plug-ins on its remote Linux or macOS machine.
2. Put a small, precompiled Herdr client core inside the signed iOS app.
3. Use the SSH implementation already present in the app to open a **non-PTY SSH exec channel per connected endpoint** that runs Herdr's `remote-client-bridge` on that machine for the selected named session.
4. Carry Herdr's framed binary client protocol directly over that SSH channel.
5. Aggregate machine/workspace/agent metadata locally, render the selected endpoint's surface, and route native touch, keyboard, paste, and image-paste actions to an explicitly identified endpoint and pane.

That gives the iPad a genuinely local UI and local clipboard integration while keeping all command execution on the user's chosen remote hosts. It also avoids downloading or executing new code on iOS, avoids depending on an `ssh` command-line subprocess, and stays aligned with Apple's requirement that apps be self-contained.

Version 0.9.0 supports several independent machines in one client, a combined agent list, and independent reconnects. It also supports different clients viewing different workspaces/tabs. This is **client-side aggregation**, not server federation: attaching to machine A does not automatically give the iPad access to A's saved machines. Each endpoint needs its own authenticated connection. The desktop's local-server endpoint is not required by the iPad product; use a connection-picker/home view when no remote machine is selected. [v0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0), [multi-machine guide](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/connecting-machines.mdx)

The most important engineering dependency is upstream cooperation, or at least a maintained fork, to extract Herdr's stable endpoint protocol and client state machinery from its current desktop binary into a reusable Rust library. Reimplementing its `bincode` wire protocol independently in Swift is possible but is not recommended: it would be fragile, tightly coupled to Rust enum layout, and easy to break when Herdr evolves.

Because the host app is already a terminal emulator, the built-in Herdr client should reuse its renderer, font system, accessibility surface, and native input integration. It should add a structured-surface provider alongside the emulator's normal VT-byte parser: Herdr has already parsed the remote PTYs, so its `PaneSurface` cells, revisions, graphics, and input metadata should be applied directly rather than converted back into ANSI.

## 1. What Herdr remote mode actually does

Herdr remote mode is not simply an SSH terminal running an interactive full-screen application. A standalone desktop `--remote` attachment does the following; multi-machine mode maintains independent endpoint connections above this transport boundary:

```text
Desktop Herdr UI
      │
      │ Herdr framed client protocol over a local Unix socket
      ▼
Local bridge process
      │
      │ ssh -T host 'exec .../herdr remote-client-bridge'
      ▼
Remote bridge over stdin/stdout
      │
      │ local Unix socket on the remote host
      ▼
Persistent remote Herdr server ── PTYs, shells, panes, agents, plug-ins
```

The source confirms this sequence. `run_remote` prepares the remote endpoint, starts an SSH stdio bridge, and then launches a local Herdr client connected through a temporary local socket ([remote attach orchestration](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/attach.rs#L32-L77)). The bridge launches the system `ssh` executable with `-T`, meaning no pseudo-terminal, and runs `herdr remote-client-bridge` remotely ([SSH transport implementation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/attach.rs#L1779-L2080)). On the remote side, the bridge copies stdin/stdout to and from the Herdr server's Unix socket ([remote bridge implementation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/host_unix.rs#L8-L33)).

The exact remote command is constructed as:

```text
exec '<remote-herdr-path>' [--session '<session-name>'] remote-client-bridge
```

See Herdr's [remote command construction](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/attach.rs#L1727-L1743). Herdr's own documentation describes the result as a thin local client attached to a persistent remote server and calls out local clipboard-image support ([remote-mode documentation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/persistence-remote.mdx)).

### The iOS substitution

On iOS, replace all three desktop-only local pieces:

- Do not spawn the `ssh` command. Use the app's SSH library and an exec channel.
- Do not create a local Unix-socket proxy. Connect the Herdr codec directly to the SSH channel's byte streams.
- Do not launch a second `herdr client` process. Link the client core into the app and call it in-process.

The resulting design is:

```text
Native iPad UI + local clipboard
      │
      │ Swift/C boundary
      ▼
Precompiled Herdr endpoint/client core in the app bundle
      │
      │ framed binary messages
      ▼
Existing iOS SSH engine: non-PTY exec channel
      │
      │ encrypted SSH stdin/stdout
      ▼
Remote `herdr remote-client-bridge`
      │
      ▼
Persistent remote Herdr server ── remote processes and storage
```

For multiple machines, repeat the endpoint-core/SSH/remote-server branch for each enabled profile and put an endpoint coordinator above those branches. Do not concatenate their framed streams into one decoder. The saved-machine desktop reference is [`connect_saved_ssh`](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/saved.rs), not a second invocation of the interactive installation-capable `--remote` orchestration.

## 2. Why the unmodified Herdr binary should not be run on iOS

Current Herdr is a desktop command-line binary, not an embeddable SDK:

- It has a binary entry point and no public `src/lib.rs` library boundary.
- Its local client launcher spawns another copy of the current executable ([client child-process launch](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/attach.rs#L2172-L2195)).
- Its desktop design expects process execution, Unix sockets, terminal behavior, and PTY-related dependencies.
- Its build script recognizes Linux, macOS, and Windows targets and rejects other targets, so `aarch64-apple-ios` does not build without changes ([target selection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/build.rs#L6-L17)). It also invokes a vendored Ghostty terminal library build through Zig ([Ghostty build integration](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/build.rs#L52-L105)).

More importantly, Apple's App Review Guideline 2.5.2 says an app must be self-contained and may not download, install, or execute code that changes the app's features or functionality. Guideline 2.5.1 requires public APIs. A precompiled Rust static library inside the signed app bundle can fit this model; downloading and launching a Herdr executable on the iPad cannot. See Apple's current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

This does **not** prevent an SSH client from asking a user-controlled remote computer to run commands. The design must make the boundary explicit: iOS executes only code reviewed and signed into the app, while the SSH connection transports user input and remote output. **Installing or updating Herdr on the remote computer is permanently outside this feature's scope.** The app connects only to a compatible Herdr installation that the user or their administrator has provisioned independently.

## 3. Recommended component architecture

### 3.1 Extract an embeddable Rust client core

Create an upstream contribution or a narrowly maintained fork that separates reusable code from the Herdr executable. A practical workspace could look like:

```text
herdr-protocol/          Stable endpoint messages, framing, limits, codecs
herdr-client-core/       Handshake, state reducer, patches, semantic input
herdr-ios-ffi/           Small C ABI and Apple XCFramework packaging
herdr/                   Existing desktop binary and server
```

The iOS core should include only what the app actually needs:

- Stable endpoint hello/welcome types and capability negotiation.
- Wire framing and exact `bincode` encode/decode behavior.
- Client-to-server message construction.
- Server snapshot, surface, and patch application.
- The client interaction reducer for pane hit-testing, selection, mouse capture, right-click policy, split/scrollbar dragging, scroll routing, focus, and resize.
- Semantic keyboard, text-commit, paste, pointer, notification, graphics, and clipboard events.
- Deterministic state exposed to the Swift UI.
- Endpoint catalog/registry, independent connection supervisors, machine-qualified state, and transactional selected-surface activation for multi-machine mode.

It should exclude:

- The Herdr server and PTY ownership.
- Shell/process spawning.
- The desktop SSH subprocess implementation.
- Local Unix-socket creation.
- Desktop configuration discovery that is not applicable to iOS.
- Remote plug-in execution or any mechanism that downloads executable iOS code.
- Desktop update logic.

Use Apple's documented Rust targets: `aarch64-apple-ios` for devices and `aarch64-apple-ios-sim` and/or `x86_64-apple-ios` for simulators. Rust classifies these as supported Apple platform targets; consult the current [Rust iOS platform-support documentation](https://doc.rust-lang.org/rustc/platform-support/apple-ios.html). Package the results as a static XCFramework with symbols stripped appropriately for release and dSYMs archived for crash diagnosis.

### 3.2 Use a narrow, ownership-safe FFI

Expose a small C-compatible API rather than leaking Rust structures into Swift. For example:

```c
herdr_client_t *herdr_client_create(const herdr_client_config_t *config);
herdr_result_t herdr_client_receive(herdr_client_t *, const uint8_t *, size_t);
herdr_result_t herdr_client_send_input(herdr_client_t *, const herdr_input_t *);
herdr_bytes_t herdr_client_drain_outbound(herdr_client_t *);
herdr_snapshot_t *herdr_client_snapshot(herdr_client_t *);
void herdr_bytes_free(herdr_bytes_t);
void herdr_client_destroy(herdr_client_t *);
```

Required FFI rules:

- No Rust panic may unwind across the boundary; catch panics and return a structured error.
- Each allocation must have one documented owner and a matching free function.
- Never retain Swift-owned pointers after a call returns.
- Do protocol parsing and state mutation on a serial executor or actor.
- Deliver immutable snapshots or small diffs to the main actor for rendering.
- Define integer widths, string encoding, and nullable fields explicitly.
- Add sanitizers to simulator CI and fuzz all byte-input entry points.

The C ABI can be generated manually or with a tool such as `cbindgen`, but the shipped interface should remain intentionally small. Any additional build tool also belongs in the build provenance record even if it is not linked into the app.

### 3.3 Integrate with the existing terminal emulator through a surface abstraction

The host app is both an SSH client and a terminal emulator. Its normal SSH sessions and its built-in Herdr client should share rendering, font, accessibility, selection, and input infrastructure, but they receive fundamentally different upstream data:

```text
Normal SSH session
SSH bytes ──> existing VT parser ──> terminal model ──> renderer

Herdr client session
SSH bytes ──> Herdr frame decoder ──> Herdr surface adapter ──> renderer
                                      │
UIKit/keyboard/pointer ──> interaction router ──> Herdr semantic messages
```

The remote Herdr server has already parsed each pane's VT stream. In client-shell mode it sends structured cell surfaces, metadata, and patches rather than a raw PTY stream. Therefore:

- Do not serialize a `PaneSurface` back into ANSI and feed it through the terminal emulator's VT parser. That would lose pane identity, content revisions, selection coordinates, hyperlink metadata, graphics placement, and exact mouse geometry while introducing an unnecessary second state machine.
- Add a render-source or surface-provider interface to the terminal emulator. The existing VT parser can implement one provider for ordinary SSH sessions; the built-in Herdr client implements another using Herdr frames.
- Reuse the emulator's glyph atlas, font fallback, Metal/Core Graphics drawing, cursor animation, selection overlay, accessibility projection, and color/theme machinery where their semantics match.
- Keep Herdr workspace chrome—tabs, sidebars, overlays, pane borders, popups, and split handles—in the client-shell state layer. It may render through native controls or the same cell renderer, but input hit-testing must use the exact geometry that produced the visible frame.

A suitable internal boundary is:

```swift
protocol TerminalSurfaceProvider: AnyObject {
    var dimensions: TerminalGridSize { get }
    var cursor: TerminalCursor? { get }
    var revision: UInt64 { get }
    func cell(at position: TerminalCellPosition) -> TerminalRenderCell
    func hyperlink(at position: TerminalCellPosition) -> URL?
    func graphicsScene() -> TerminalGraphicsScene
}
```

This is an application-owned abstraction, not a proposal to reproduce Herdr's wire types in Swift. The Rust core should validate and own the protocol objects, then expose immutable render snapshots or bounded diffs through the FFI.

### 3.4 Do not independently recreate the binary protocol in Swift

Herdr's outer stream is length-framed `bincode`, not JSON. Each message is encoded as a little-endian 32-bit length followed by a `bincode` payload; the decoder requires full payload consumption and enforces frame-size limits ([framing implementation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1591-L1657)). The client and server enums explicitly depend on frozen variant order ([client message enum](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L465-L622), [server message enum](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1324-L1448)).

Although endpoint control records contain JSON, that JSON is carried inside the outer protocol. A hand-written Swift decoder would duplicate Rust serialization details and could silently diverge. Reusing Herdr's Rust types and codec is both safer and easier to validate against upstream releases.

### 3.5 Multi-machine coordinator and profile model

Within a client scene, use one endpoint client instance for each saved **SSH target plus explicit Herdr session**. A profile does not enumerate every session on the host; two profiles may intentionally address different sessions on the same machine. Native profiles should contain an opaque stable ID, user-facing label, reference to the app's SSH profile, explicit session, enabled state, and user-approved executable-path/connection preferences. Credentials remain in the existing SSH/Keychain layer. Do not use a label, hostname, or pane ID as the profile's identity. [Upstream profile model and validation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/catalog.rs#L10-L71), [endpoint IDs/statuses](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint.rs#L22-L89)

Keep these responsibilities separate:

| Layer | Scope and responsibility |
| --- | --- |
| Saved profiles | Persistent connection intent; adding/removing/renaming does not provision remote software. |
| Endpoint runtime | Its own SSH exec stream, decoder, negotiation, request IDs, connection generation, server boot identity, snapshot/surface state, health and write queue. |
| Per-scene coordinator | Combined machine/workspace/agent navigation, selected endpoint, safe activation transaction, and visible terminal surface. |
| Shared app services | SSH credential/host-trust policy, rendering primitives, clipboard policy, notifications, and global resource budgets. |

The existing illustrative `herdr_client_t` FFI can remain per endpoint. Wrap every callback and asynchronous request with its endpoint identity and connection generation, and maintain activation state above those instances. Do not put all machines behind a single serial network writer: one stalled host must not block input to another.

Inactive connected endpoints should continue metadata and notification updates but stop pane-screen streaming. The selected endpoint supplies the scene's pane input, viewport and graphics. Do not implement an always-live grid of every host's screens as an accidental consequence of aggregation; simultaneous visible surfaces would require a separately designed subscription/ownership policy. [Connection registry](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/registry.rs), [inactive-message policy](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/message_policy.rs)

The desktop assumes a `Local` endpoint and falls back to it in several paths. Adapt those paths explicitly: on iPad, no selection, removal of the selected profile, or an unavailable endpoint leads to a neutral home/disconnected view. Do not start a local Herdr server, merge an ordinary native terminal into a Herdr endpoint, or silently select a different remote host. For multiple iPad windows, keep selection/focus and viewer ownership per scene rather than one global app-wide “active machine.”

Independent scenes viewing the same profile need independent logical Herdr client/viewer connections, or an explicit single-owner transfer policy. They may share an underlying SSH connection through separate exec channels; one Herdr client connection cannot independently own both scenes' surfaces and focus. Include viewer identity in shared state/request correlation rather than treating the profile alone as the live client.

### 3.6 Machine-qualified identity and command routing

Two servers can both have `w1:p1`, tab 1, and an agent called `reviewer`. Treat the iOS routing key as:

`(profile ID, connection generation, server boot ID, server-local object ID)`

This is app-side routing metadata, not a new field appended to the frozen wire enum. Include the originating endpoint in request/response correlation, selections, image/texture caches, clipboard requests, notifications and pending commands. Within one boot, continue validating projection/content/surface revisions. A reconnect changes connection generation; a server restart changes boot identity; neither permits a late response to mutate a replacement connection. [Activation identity](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/activation/model.rs), [request and surface correlation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/activation/protocol.rs)

For app-wide storage shared by independent scenes, also qualify this key with the logical viewer/scene ID, or use a globally unique connection-instance ID. Connection-generation counters local to two scenes must not collide in shared routing tables.

Show a machine/session label in the combined agent list, action confirmation, connection error, and notification destination. A toolbar action captures the intended endpoint when invoked, not when its asynchronous work finishes. Destructive workspace/pane actions must never infer a target from the first matching ID across machines.

Switching the UI does not retarget a CLI command already running inside a pane: it remains attached to that pane's remote environment/session. Do not invent a global `--machine` routing flag or propagate iPad selection into remote shell environment variables. Cross-machine automation must explicitly use the intended host/session and resolve IDs there. [Machine-scoped automation semantics](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/connecting-machines.mdx#L67-L75)

## 4. Compatibility contract and handshake

Herdr has two different notions of compatibility:

- An internal/private wire protocol version, `22` in v0.9.0.
- A stable endpoint generation, currently generation `1`, with named codecs and capabilities.

The released iOS client should use the stable endpoint contract. Herdr describes it as independent of the private protocol and designed to preserve compatibility across local, SSH, and cloud transports ([endpoint contract and codecs](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/endpoint.rs#L1-L29)). The existing client sends an endpoint hello, expects an endpoint welcome, and validates generation and negotiated codecs ([handshake implementation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/handshake.rs#L149-L260)).

Do not advertise a codec or capability until the iOS app fully implements and tests it. A conservative first hello should include:

- Endpoint generation 1.
- Supported shell snapshot and surface codecs.
- Supported semantic-input codec.
- The required blob codec (`shell.blob.v1`), implemented and tested rather than advertised speculatively.
- Logical row/column dimensions and, when known, pixel dimensions.
- Keyboard-binding preference.
- Focus and active-surface state.
- Mouse capability only when pointer/touch translation is implemented.
- `direct_graphics = false` initially; add graphics only after memory and rendering hardening.

If the generation or required codecs are not compatible, stop with a clear message that reports the local app version, remote Herdr version, endpoint generation, and a safe remediation. Do not fall back silently to the private handshake.

### Multi-machine admission and per-action capabilities

Negotiate separately with every endpoint. Matching release numbers are not required, and a compatible server must not be restarted simply because the app contains newer client code. Inspect both the installed binary and the running server; an updated executable on disk does not prove the existing daemon has new capabilities.

For v0.9.0-style saved-machine participation, the exact client checks require all of:

- `surface_interest` capability;
- `presentation_effects_fence` capability;
- advertised `client_shell.surface.set` method;
- `health_check` capability for SSH endpoints.

The user guide summarizes this as surface-interest and health support, but the [actual negotiation predicate](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/registry.rs#L23-L60) also requires the presentation fence and method. Preserve those stronger checks and the [supervisor's admission behavior](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/supervisor.rs#L280-L310). Inactive background connections should request `surface_active = false` in their hello; obtain a fresh selected surface through activation before enabling input.

If one endpoint lacks these requirements, mark **that profile** Attention/incompatible; other endpoints remain usable. A separately qualified single-endpoint mode may still work, but do not silently admit it to multi-machine mode. Missing optional methods disable only their corresponding UI actions on that endpoint, not the whole app. Never send an unsupported method speculatively or offer an installation/restart remedy inside the app. [Stable endpoint welcome and capabilities](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/endpoint.rs#L15-L118)

### Ask upstream for a stronger public boundary

Before committing to a store release, open an upstream design discussion requesting:

1. A published `herdr-protocol` or `herdr-client-core` crate.
2. A documented support policy for stable endpoint generation 1.
3. Golden encoded frames and cross-version conformance fixtures.
4. Fuzz targets for framing and patch application.
5. Advance notice or capability negotiation for incompatible behavior.
6. Ideally, a language-neutral stable transport such as explicitly specified CBOR or JSON for future non-Rust clients.

The current endpoint layer is promising, but source-level documentation is not the same as a versioned third-party SDK commitment.

## 5. SSH transport implementation

Reuse the SSH engine already in the iOS client. Put it behind a transport interface so Herdr knows only that it has an ordered duplex byte stream:

```swift
protocol HerdrByteTransport: Sendable {
    func write(_ bytes: Data) async throws
    func inboundBytes() -> AsyncThrowingStream<Data, Error>
    func closeWrite() async throws
    func close() async
}
```

### Required channel behavior

- Open an SSH **session exec** channel, not an interactive shell and not a PTY.
- Send the fixed remote command for `remote-client-bridge`.
- Preserve stdout as an opaque binary stream. Never decode it as UTF-8 or normalize newlines.
- Keep stderr separate. It may contain diagnostic text and must never enter the protocol decoder.
- Support arbitrary chunking: one SSH data callback may contain part of a frame or several frames.
- Respect backpressure. Do not allow an unbounded queue between the network and decoder.
- Support half-close/EOF so normal remote shutdown is distinguishable from network failure.
- Keep SSH host-key verification and authentication identical to normal app sessions.
- Disable agent forwarding, port forwarding, and PTY allocation unless separately needed and explicitly enabled.

If the app uses SwiftNIO SSH, it supports SSH session channels, exec requests, public-key/password authentication, and modern algorithms; however, its maintainers describe it as building blocks rather than a complete production-ready client. The relevant APIs are `SSHChannelRequestEvent.ExecRequest`, `SSHChannelData`, and remote half-closure. Review its current [repository and documentation](https://github.com/apple/swift-nio-ssh) and [Apache-2.0 license](https://github.com/apple/swift-nio-ssh/blob/main/LICENSE.txt). If the existing SSH engine already provides these primitives, changing libraries would add risk without architectural benefit.

### Command construction and injection resistance

The executable path and optional session name eventually enter a remote shell command. Treat both as hostile input:

- Prefer a fixed wrapper whose only variable is a server-selected executable path already returned by a trusted probe.
- If shell construction is unavoidable, use one centralized POSIX-shell quoting routine with tests for spaces, quotes, newlines, leading dashes, and non-ASCII.
- Validate session names against Herdr's own accepted grammar before quoting.
- Never concatenate arbitrary UI text into the command.
- Never log passwords, private keys, terminal contents, protocol frames, clipboard data, or the complete command when it contains sensitive identifiers.

## 6. Connection lifecycle

A robust connection should use the following state machine.

### 6.1 Discovery and preflight

1. Resolve the saved SSH host, port, username, proxy/jump configuration, and key policy through the app's existing connection profile.
2. Establish SSH and verify the host key. Never provide an “accept any host key” route for Herdr.
3. Open a short-lived, non-PTY probe channel.
4. Detect the remote OS and architecture and find `herdr` in expected locations. Current desktop support recognizes Linux/macOS on x86-64/aarch64 ([remote platform detection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/attach.rs#L136-L179)).
5. Run Herdr's client-status/probe operation, parse structured output, and verify endpoint generation and capabilities.
6. Require an already-installed compatible remote Herdr in every release. If none is found, stop at a diagnostic screen and link to the official Herdr installation documentation; do not offer or execute an installation command.

### 6.2 Main connection

1. Open a new non-PTY exec channel using the verified executable path.
2. Execute `remote-client-bridge`, optionally with a validated named session.
3. Attach the channel's stdout bytes directly to the Rust decoder and the core's outbound frames to stdin.
4. Send the stable endpoint hello and enforce a handshake timeout. The desktop source allows a longer timeout for remote connections ([remote handshake timeout](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/handshake.rs#L25-L33)).
5. Validate the welcome before rendering or accepting user input.
6. Apply full snapshots and subsequent surface patches in order.
7. Send semantic keyboard, paste, pointer, focus, active-pane, and resize messages.

### 6.3 Disconnect and recovery

- Distinguish user detach, server shutdown, clean EOF, protocol violation, authentication loss, and transient network loss.
- Stop accepting input immediately when transport ordering can no longer be guaranteed.
- Close the write side, drain only for a bounded period, then close the channel.
- Retain no secret or clipboard payload in crash reports.
- On foreground/network recovery, create a new bridge and request authoritative state rather than replaying speculative input.
- Use bounded exponential backoff with jitter, a visible reconnect state, and a manual cancel control.
- Because the server is remote and persistent, reconnecting should recover the workspace without trying to keep iOS alive indefinitely.

### 6.4 Independent multi-machine lifecycle

Run discovery, handshake, retries and failure handling independently for each enabled profile. Mirror the meaningful states `Connecting`, `Online`, `Reconnecting`, `Attention`, and `Disabled`; an endpoint can be online for metadata without being selected or input-ready. Preserve dimmed, explicitly stale metadata during disconnection and disable actions into stale panes. Recovery must not steal selection from a machine the user is currently using.

Use bounded parallel connection attempts and separate bounded writes. Upstream's writer limits messages/bytes and treats queue/write failure as an endpoint failure rather than dropping arbitrary input frames. Choose measured per-endpoint **and aggregate** iPad memory/texture/queue limits; multiplying a desktop-sized allowance by dozens of machines is not a safe mobile budget. [Endpoint writer](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/writer.rs)

SSH keepalives alone do not prove that a remote Herdr server is responsive. Use the negotiated application-level health controls; v0.9.0 probes after five seconds of inactivity and uses a ten-second timeout, including an initial-snapshot deadline. Those values are implementation references, not permission to run timers indefinitely in the background. On iPad foreground recovery, reestablish endpoints with jitter and fresh state. [Health state machine](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/health.rs)

Host-key changes, authentication requiring user action, and incompatible servers should enter Attention with an explicit local action—not a background prompt answered automatically. Disable/remove affects only that profile's connection and local saved state; it must not stop the remote session or its agents, even when the host is unreachable. Distinguish “Disconnect machine” from any separately authorized remote shutdown command.

### 6.5 Switching machines is a transaction

Do not implement a machine switch as changing a pointer to the current socket. Reuse or faithfully port Herdr's activation state machine:

1. Capture source/target leases, requested workspace/tab/pane, and current cell/pixel geometry; validate negotiated support before transport writes.
2. Freeze pane input. Settle/cancel the source's pressed-key, mouse-drag and selection state without delivering releases to a different machine.
3. Revoke source focus and deactivate its surface interest; handle its acknowledgment/order according to the upstream transaction.
4. Send target resize, activate surface interest, establish foreground focus and any explicit navigation request, and wait for matching snapshot/surface evidence for its current connection generation and server boot.
5. Require coherent projection revision and viewport geometry, then commit the selected endpoint and target frame atomically **while keeping pane input frozen**.
6. Perform the post-commit surface/presentation resynchronization. Apply the target's mode/effect replay to its committed frame, then await the matching `endpoint.presentation.sync.v1` / `endpoint.presentation.ready.v1` fence before unfreezing pane input. Do not discard the valid replay needed to establish the target's presentation state.

On timeout, disconnect or cancellation, restore the source coherently where possible or show an unavailable surface. Never release buffered keystrokes into another machine as a fallback. The distinction between committing the visible target, replaying its presentation state, and enabling input is essential. [Commit and post-commit synchronization](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/activation.rs#L880-L975), [client runtime fence handling](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/shell_runtime.rs#L310-L370)

The activation implementation handles stale evidence, rollback and successor switches; preserve those behaviors rather than reducing this to one asynchronous callback. Its presentation synchronization is an endpoint UI transition, not the experimental server-process live handoff that remains outside app-managed maintenance. [Activation state machine](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/activation.rs), [coherence checks](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/activation/protocol.rs)

Version 0.9.0 also changes shared-server expectations: different clients may view different workspaces/tabs independently; when they view the same tab, the last client to interact controls its size. Do not assume one global server-selected workspace or perpetual iPad resize ownership. Exercise the iPad beside another desktop/iPad client, including after focus loss and reconnect. [v0.9.0 multi-client behavior](https://github.com/herdrdev/herdr/releases/tag/v0.9.0)

## 7. Rendering and input choices

There are two credible implementation paths.

### Option A — native iOS shell UI (recommended)

Use the Rust core to maintain Herdr state and expose a render-neutral pane/surface model. Render tabs, pane chrome, command surfaces, popups, notifications, and selection with native Swift/UIKit or SwiftUI components; continue using the app's existing terminal grid for pane contents.

Advantages:

- Best touch, selection, paste, accessibility, pointer, external-keyboard, and Stage Manager integration.
- Smaller Rust/UI dependency footprint.
- Clear separation between remote execution and local presentation.
- Easier to comply with iOS lifecycle and memory constraints.

Costs:

- More UI mapping work.
- Requires a stable render/state API from the client core, not only raw protocol frames.
- Pixel-perfect parity with Herdr desktop may lag initially.

### Option B — reuse more of Herdr's Rust client and render a cell surface

Port the desktop client state/rendering layer, but replace its terminal backend with a render target that emits a neutral cell grid or renderer commands into the app's existing terminal view.

Advantages:

- Faster visual parity if the relevant code can be separated cleanly.
- Less duplication of Herdr-specific UI semantics.

Costs:

- Larger dependency and license surface.
- More desktop assumptions to remove.
- Harder native accessibility, selection, input-method, and touch behavior.
- Vendored Ghostty code may become part of the shipping binary and therefore part of the audit.

### Fallback/MVP — regular remote terminal

Opening a PTY and running interactive `herdr`, or using the documented newline-delimited JSON single-terminal controller, can validate demand but does not achieve the requested local Herdr workspace and clipboard integration. It is a useful fallback when protocol negotiation fails, not the target architecture. The JSON controller is documented under Herdr's [third-party observer/controller interface](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/persistence-remote.mdx).

### Terminal-surface fidelity requirements

Using Herdr's structured surface does not eliminate terminal-emulator work; it changes the boundary from “parse VT bytes” to “faithfully display and interact with an authoritative terminal grid.” The existing renderer and terminal model must be able to ingest or represent all fields carried by Herdr's [`CellData`, `CursorState`, and `FrameData`](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L700-L767):

- Complete grapheme strings, including combining marks, emoji sequences, variation selectors, and zero-width content.
- Wide-cell head/tail or skip behavior without independently recomputing display width from a different Unicode version.
- Indexed, default, and true-color foreground/background values using the Herdr color encoding.
- Every style bit defined by the negotiated surface codec, including underline extensions rather than only basic bold/italic flags.
- Cursor position, visibility, shape, and local blink timing.
- OSC 8 hyperlink indices and their URI table.
- Embedded graphics associated with the frame.

Full surfaces and patches must be applied as a revisioned state machine. A `PaneSurfaceFrame` identifies the endpoint boot, projection revision, surface revision, panes, splits, popup, and graphics scene; a patch names both its base and resulting surface revisions ([surface and patch definitions](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1211-L1254)). The client must:

- Apply updates only to the matching endpoint boot and base surface revision.
- Reject or request a fresh full surface after a gap, duplicate with conflicting content, or endpoint restart.
- Validate `cells.count == width * height`, patch rectangles, hyperlink indices, graphics references, and all arithmetic before allocation or drawing.
- Commit a frame atomically so text, cursor, pane metadata, hit regions, and graphics cannot be observed at different revisions.
- Run network decoding and state reduction off the main actor; publish bounded immutable render changes to the UI.
- Coalesce superseded redraws without dropping protocol state transitions.

Pane metadata supplies authoritative outer/inner rectangles, scrollbars, scroll metrics, focus, application mouse-reporting state, SGR pixel-mouse state, alternate-screen state, and pane pixel dimensions ([pane surface metadata](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1079-L1101)). The terminal view must use this metadata for input routing and selection rather than deriving a second, slightly different pane layout.

### Keyboard, text input, and terminal modes

Do not reduce iPad input to UTF-8 character bytes. Herdr's stable semantic pane events distinguish key presses, repeats, releases, generated text, shifted code points, physical-key identity, committed text, mouse events, and paste ([semantic input definition](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L152-L178)). The remote terminal runtime then encodes those events according to the application-negotiated legacy or Kitty keyboard protocol.

The iOS input layer should:

- Use UIKit responder key events for physical press and release lifecycle; Apple's [physical-keyboard guidance](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard) documents `pressesBegan` and `pressesEnded`.
- Track repeats without fabricating duplicate text commits.
- Preserve Control, Option/Alt, Shift, and Command/Super where representable, plus the character, function, navigation, editing, and control keys defined by `ClientKeyCode`; attach a stable physical-key identity where the protocol accepts it.
- Use [`UITextInput`](https://developer.apple.com/documentation/uikit/uitextinput) or an equivalent system-integrated text-input surface for committed and marked text. Do not send marked CJK/IME composition as final input until the text system commits it.
- Keep physical key events and text commits separate so a printable hardware key is not sent twice.
- Respond to `ClientShellKeyboardReportAll` by retaining the complete key lifecycle required by the focused pane or popup.
- Route shell-owned shortcuts before pane input, using the selected local-versus-endpoint keybinding policy from the endpoint handshake.
- Send `ClientShellFocus` when the terminal scene gains or loses effective foreground focus so remote applications that enabled terminal focus reporting receive correct transitions.
- Treat software-keyboard accessory keys such as Escape, Tab, Control, arrows, and function keys as semantic key events, not pasted text.

Keyboard conformance should be tested with ordinary shells, Vim/Neovim, Emacs, `tmux`, full-screen TUIs, applications using Kitty keyboard flags, non-US layouts, dead keys, emoji, CJK IMEs, key repeat, and press/release-sensitive applications.

The current stable `ClientKeyCode` is intentionally smaller than the complete iPad hardware-key universe: it does not separately encode keypad, media, Caps Lock, or arbitrary HID keys ([current key-code enum](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L57-L84)). Map only equivalent supported keys and text commits. Additional physical-key semantics require an upstream negotiated capability; do not append locally to the frozen `bincode` enum.

### Full mouse and pointer support

The built-in client needs a normalized pointer-event layer between UIKit/Game Controller input and Herdr. Herdr currently represents left, right, and middle buttons; down, up, drag, and movement; vertical and horizontal wheel events; modifier bits; a scroll-line count; cell coordinates; and optional exact pixel coordinates plus geometry ([mouse protocol types](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L86-L125), [pane mouse event payload](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L157-L178)).

Use public Apple input APIs appropriate to the device:

- [`UIHoverGestureRecognizer`](https://developer.apple.com/documentation/uikit/uihovergesturerecognizer) provides absolute pointer location and hover within the terminal view.
- [`GCMouseInput`](https://developer.apple.com/documentation/gamecontroller/gcmouseinput) exposes raw movement, scroll, left/right/middle buttons, and any auxiliary physical buttons.
- [`UIScrollType`](https://developer.apple.com/documentation/uikit/uiscrolltype) distinguishes continuous trackpad scrolling from discrete mouse-wheel scrolling. Accumulate continuous deltas into deliberate Herdr line counts rather than emitting one line for every subpixel callback.

Normalize platform events into one ordered event stream with source identity, timestamp, button, phase, view position, current keyboard modifiers, and wheel delta. Avoid emitting the same click twice when UIKit gesture recognition and `GCMouseInput` both observe it.

The interaction router must separate three destinations:

1. **Herdr chrome:** tabs, workspace/sidebar entries, overlays, menus, pane borders, split handles, and scrollbars.
2. **Herdr selection/navigation:** pane focus, text selection, double-click word selection, copy mode, and host scrollback.
3. **The pane application:** terminal mouse reports requested by the focused application.

The visible surface determines ownership. When a pane reports `mouse_reporting = true`, movement and eligible button events inside its inner rectangle are forwarded as semantic pane mouse events. Otherwise, left-button drags create a Herdr selection. Wheel input may become an application mouse report, alternate-screen arrow scrolling, or host scrollback; the remote terminal runtime makes that final decision, so the iOS view must not also scroll its own independent buffer. Herdr's server-side routing covers these cases ([terminal mouse and scroll encoding](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/pane_input.rs#L130-L185), [semantic pane mouse handling](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/pane_input.rs#L217-L288)).

The remote runtime—not the iOS terminal emulator—owns DEC mouse-mode encoding, including button, drag, any-motion, SGR cell coordinates, and SGR pixel mode. The iOS client sends semantic pointer events and follows `mouse_reporting`/`sgr_pixel_mouse`; it must not independently emit xterm mouse escape sequences.

Required gesture-state rules:

- On button down, capture the selected destination, pane/popup identity, and current surface geometry.
- Deliver matching drag and button-up events to that same destination even if the pointer crosses a split, a new surface arrives, or the pointer leaves the pane.
- Maintain independent pressed state for left, middle, and right buttons and guarantee a terminal release on recognizer cancellation where the original press was delivered.
- Clamp or downgrade coordinates safely when geometry changes; never reinterpret an in-flight gesture against a different pane.
- Forward hover/moved events to pane applications only while their reported mouse mode requires them. Local Herdr hover effects can remain active for chrome.
- Forward the keyboard modifiers that were active for each event, not the modifiers cached at button-down time, except where Herdr's right-click policy deliberately strips a configured routing modifier.
- Preserve horizontal wheel direction even when the local terminal UI has no horizontal scrollbar.
- Debounce or coalesce high-frequency motion without reordering it across button, focus, or resize events.

Right-click is policy-driven. It normally opens Herdr's context menu, but a pane may declare `right_click_passthrough`, or a configured modifier may explicitly forward it to an application that requested mouse reporting. Herdr's existing client implements this distinction ([right-click routing](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/shell/mouse.rs#L1667-L1715)). Ctrl-click hyperlink activation, a failed-link replay, double-click word selection, pane focus, scrollbar dragging, and split dragging are also client-side behaviors worth extracting or reproducing from the existing interaction reducer ([pane routing and selection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/shell/mouse.rs#L2020-L2221)).

For SGR pixel mouse mode 1016:

- Derive pixel coordinates from the actual terminal render target or drawable and its content scale, including Split View, Stage Manager, external displays, and display zoom.
- Map into the pane's reported pixel width/height and use 1-based coordinates as expected by the terminal protocol.
- Send the matching cell rows/columns and a `ClientMouseGeometry` with every pixel-positioned event.
- Advertise `pixel_mouse = true` only while the reported cell grid and pixel extent are exact and synchronized. During a live resize or unknown geometry, send cell coordinates until the next authoritative surface is committed.
- Test fractional point-to-pixel scaling and every edge cell. Herdr validates geometry and downgrades ineligible pixel events rather than trusting mismatched dimensions ([pixel-mouse validation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/pane_input.rs#L6-L40)).

Herdr's current endpoint model cannot transmit auxiliary mouse buttons beyond left, right, and middle, even though `GCMouseInput` can observe them. Ignore or reserve those buttons for local app navigation unless upstream adds an advertised capability or future endpoint control. Do not change the frozen `bincode` enum locally because that would break generation-1 compatibility.

Recommended touch mapping is deliberately different from physical mouse input:

- Tap focuses a pane and positions the Herdr selection anchor as appropriate.
- Drag selects text by default.
- Double-tap requests server-authoritative word selection.
- Two-finger pan produces vertical or horizontal scroll.
- Long press opens the Herdr/iOS context menu.
- An explicit per-session “application mouse mode” may translate touch gestures into pane mouse reports for TUIs that require them.

This prevents normal iPad selection and scrolling gestures from accidentally clicking controls inside Vim, `htop`, `tmux`, or another mouse-aware application.

### Graphics, links, title, bell, and notifications

For the first implementation, prefer the structured `SurfaceGraphicsScene` carried with `PaneSurface`, not raw direct-to-host Kitty graphics. Its assets are RGB, RGBA, or PNG and its placements include source rectangles, offsets, cell extents, z-order, and scrollback offsets ([graphics scene definitions](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1139-L1209)). The terminal emulator should:

- Decode graphics off the main actor with strict dimension, decoded-byte, and texture-memory budgets.
- Cache by the complete Herdr asset key/fingerprint and retire assets when the authoritative scene no longer retains them.
- Clip placements to their pane/popup, apply z-order consistently with text, and update placement geometry on scroll/resize even when asset bytes are unchanged.
- Drop the scene and request a fresh surface if an asset reference is missing or inconsistent.

Map OSC 8 hyperlink metadata into the terminal view's link model. Open only validated user-initiated URLs and preserve Herdr's click-versus-terminal-mouse routing. Present `WindowTitle`, `TerminalBell`, `Notify`, and `SemanticNotification` through native UI, sound, or haptics according to user settings and foreground state; these server-to-client events are defined in the [server message protocol](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1324-L1448).

## 8. Clipboard and local-device integration

Clipboard behavior is one of the strongest reasons to build a local client, but it also creates a trust boundary between the remote host and the iPad.

In multi-machine mode, this boundary is per endpoint, not merely per app. Capture the machine/session/boot/pane when starting text copy or asynchronous image paste. If the user switches machines before completion, cancel or explicitly reconfirm the original destination; never paste into whichever machine happens to be active later. A remote temporary image path belongs to the machine that created it and must not be reused on another host.

Inactive endpoints may contribute metadata and semantic notifications, but must not overwrite the local clipboard, title, graphics, bell state, mouse capture, or keyboard-reporting mode. During an activation transaction, discard stale presentation effects and follow the post-commit fence. Attribute notifications to their source endpoint; tapping one requests safe activation and resolves a fresh target before acting. [Endpoint message and presentation policy](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint/message_policy.rs)

### 8.1 Local selection and text copy

Do not rebuild copied text by concatenating the visible render cells. That produces incorrect results for soft-wrapped lines, scrollback, wide graphemes, combining marks, and output that changes during a gesture.

The client should:

1. Keep selection endpoints as a pane ID plus absolute terminal row and column. Convert viewport rows using the pane's authoritative scroll metrics.
2. Draw the local highlight immediately, but ask the endpoint for the actual text with `pane.selection.read` when the user copies.
3. Include the pane `content_revision` when the copy must correspond exactly to a committed surface. For a deliberately live selection, follow Herdr's current behavior and omit that revision so intervening output does not cause an unnecessary rejection.
4. Accept only a response matching the pending request, endpoint boot, and pane.
5. Write the returned text to the iPad pasteboard and then provide visible or haptic confirmation without logging the text.

Herdr's existing client follows this server-authoritative selection flow ([selection-copy request](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/shell/actions.rs#L250-L281)). Double-click word selection should also ask the endpoint to resolve the word from terminal content rather than applying an unrelated iOS word tokenizer.

Support drag selection with scrollback autoscroll, double-click word selection, keyboard copy mode where exposed, and an optional `copy_on_select` preference. A conventional explicit Copy action is the safer iPad default.

### 8.2 Text paste from iPad to remote pane

- Make paste explicitly user initiated: a menu action, keyboard shortcut, context menu, or `UIPasteControl`.
- On iOS 16 and later, arbitrary programmatic reads may show a paste-access prompt. Apple's [`UIPasteControl` documentation](https://developer.apple.com/documentation/uikit/uipastecontrol) describes the user-mediated control intended for paste workflows.
- Read only the types needed for the chosen action.
- Send the exact approved text as `ClientPaneInputEvent::Paste` to the captured pane or popup target. Do not pre-wrap it in bracketed-paste escape sequences; the remote terminal runtime owns that decision based on the active terminal mode.
- Keep paste into local Herdr overlays, search fields, or rename controls local rather than routing it to the remote pane.
- Offer a confirmation threshold for unusually large pastes and show the destination pane/session.
- Cancel or reconfirm if the target pane/popup or endpoint boot changes between reading the pasteboard and sending the event.

### 8.3 Remote clipboard writes to iPad

Herdr can send clipboard content as a server message; the reviewed protocol carries base64 clipboard text ([server message definitions](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1324-L1448)). Treat this as remote-originated data:

- Decode with an explicit maximum size before allocating large buffers.
- Reject invalid base64 and unexpected content types.
- Default to a visible “Copy from remote” action or an opt-in per-host setting rather than silently overwriting the system clipboard.
- Attribute the action to the host and pane to reduce clipboard-poisoning risk.
- Never include copied content in analytics or logs.

### 8.4 Image paste

Herdr's client supports sending clipboard image bytes with a target and extension and limits them to 16 MiB ([client image-paste path](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/clipboard_images.rs#L12-L42)). The server writes the image to a private remote temporary directory, chooses an extension from a limited set, and performs stale cleanup ([remote image staging](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/clipboard_image.rs#L6-L110)). It then validates the active client/pane or popup before inserting the remote path ([target validation and injection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/headless.rs#L1182-L1324)).

For iOS:

1. Require an explicit paste, Photos picker, Files picker, drag/drop, or share action.
2. Load through an item provider and enforce the 16 MiB decoded limit during streaming, before retaining the whole object where possible.
3. Decode and re-encode supported formats rather than trusting the supplied extension or metadata.
4. Strip EXIF/location metadata by default, with a clearly labeled option if metadata preservation is required.
5. Downscale very large images with a visible quality/size choice.
6. Bind the operation to the pane/popup that was active when the user invoked paste; cancel or reconfirm if focus changes before sending.
7. Explain that the image becomes a temporary file on the remote host and that cleanup is ultimately governed by that Herdr server version.

Herdr's reviewed wire constants allow approximately 2 MiB normal frames, 32 MiB graphics frames, and 16 MiB clipboard-image frames ([wire limits](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L19-L35)). Enforce independent iOS-side limits before asking the Rust decoder to allocate.

## 9. Security requirements

### SSH and credentials

- Use strict host-key verification with a known-hosts model and a prominent first-use fingerprint screen.
- Make changed host keys a blocking error, not a warning hidden behind reconnect.
- Store private keys, passwords, and key passphrases using Keychain Services; apply the narrowest practical accessibility class and access-control policy. See Apple's [Keychain Services documentation](https://developer.apple.com/documentation/security/keychain-services) and [storing keys in the Keychain](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain).
- Prefer user-selected keys or Secure Enclave-backed authentication where the SSH library supports it.
- Do not export a private key merely to satisfy a Rust API; pass signatures or protected key handles when possible.
- Keep agent forwarding off by default.

### Protocol hardening

- Treat all remote frames as untrusted even after SSH authentication.
- Reject over-limit lengths before allocating.
- Use checked arithmetic for frame sizes and pixel/cell dimensions.
- Require full message consumption and reject trailing data.
- Bound decompression, patch count, cell count, graphics dimensions, queue depth, and per-frame processing time.
- Disconnect on malformed or out-of-order state rather than attempting unsafe recovery.
- Fuzz length parsing, `bincode` decoding, endpoint JSON, patch application, image metadata, and FFI buffer ownership.
- Maintain golden tests captured from supported Herdr server versions.
- Run malformed-server tests over a fake byte transport without involving a real SSH server.

### Data and privacy

- Redact usernames, hostnames, IP addresses, remote paths, session names, terminal contents, and clipboard data from telemetry by default.
- Keep diagnostic protocol logging opt-in, time-limited, visibly active, and locally exportable by the user.
- Define retention for recently used hosts and session names.
- Encrypt sensitive local state through iOS data protection and exclude ephemeral terminal/clipboard caches from backups when appropriate.
- Provide a per-host “forget” action that removes known-host, credential reference, recent-session, and cached metadata without deleting unrelated SSH profiles.

## 10. iOS lifecycle and networking

### Backgrounding

Do not promise that the SSH channel will remain connected indefinitely while the app is backgrounded. iOS grants limited time to finish work, and background modes are restricted to their intended purposes. Apple's guidance covers choosing a permitted [background strategy](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app) and requesting only limited additional time to [finish work after entering the background](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

Recommended behavior:

1. When the scene resigns active, stop accepting interactive input and persist only non-sensitive UI state.
2. Request a short background task if needed to send a clean detach/EOF and flush safe metadata.
3. Close the SSH channel before the granted time expires.
4. On foreground, reconnect and obtain an authoritative snapshot from the persistent remote Herdr server.

Do not claim audio, VoIP, location, or another unrelated background mode merely to preserve SSH. If remote notifications while disconnected are later required, design a separate opt-in server/APNs feature with its own privacy, authentication, and threat review; an SSH socket alone cannot reliably wake a suspended app.

### Local-network and IPv6 behavior

Connections to hosts on the local network may trigger Apple's local-network privacy controls. Include a clear `NSLocalNetworkUsageDescription` when applicable and request access in context; see Apple's [local-network privacy technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) and [`NSLocalNetworkUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription).

Test:

- IPv4, IPv6, and DNS hostnames.
- Apple's IPv6-only network requirement under App Review Guideline 2.5.5.
- Wi-Fi-to-cellular transitions.
- Captive portals and unreachable jump hosts.
- Split tunnels and on-demand VPNs.
- LAN denial followed by later permission changes.
- ProxyJump/bastion profiles already supported by the host app.

## 11. Remote Herdr prerequisite and management boundary

Herdr must be installed and maintained on the remote machine before the app connects. This is a permanent product boundary, not a version 1 limitation.

It applies to **every saved machine and session**. Upstream `herdr machine add` is not just a catalog write: it calls remote preparation, which can ask to install/replace Herdr and start its server. The iPad's Add Machine action must instead save an app-owned profile and run an attach-only compatibility check. Do not invoke `herdr machine add`, `prepare_saved_ssh`, or interactive `--remote` setup as a hidden implementation shortcut. Reuse the transport/preflight ideas from `connect_saved_ssh` while substituting native SSH and preserving the stricter no-installation policy. [Machine command implementation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/cli/machine.rs#L86-L164), [attach-only saved connection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/saved.rs)

Desktop commands `machine list [--json]`, `rename`, `enable`, `disable`, and `remove` describe useful profile-management concepts, but the iPad should implement those concepts against its own store. Reading a desktop catalog is an optional import operation, not discovery of a server-side federation. Validate imported targets and map them to the app's existing SSH profiles; do not copy remote credentials or change remote configuration. [Machine CLI contract](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/cli/machine.rs#L4-L25)

The iOS app may:

- Detect the remote OS and architecture for diagnostics.
- Search a documented, bounded set of paths for an existing `herdr` executable.
- Query the installed version, endpoint generation, capabilities, and server status.
- Start or attach to the server through the already-installed executable when that is part of the normal `remote-client-bridge` flow.
- Report an actionable incompatibility and link to Herdr's official documentation.
- Retry after the user or administrator completes maintenance outside the app.

The iOS app must never:

- Download, upload, install, replace, update, patch, rename, or change permissions on a Herdr executable.
- Run a package manager, installation script, or copied setup command on the user's behalf.
- Use `sudo` or otherwise elevate privileges to prepare Herdr.
- Stop or replace an existing Herdr server as part of a software update.
- Install or update Herdr plug-ins.
- Bundle remote-platform Herdr release assets as app resources.
- Execute or offer the `update_install_command` carried in a `ClientShellSnapshot` ([snapshot update fields](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L905-L925)); treat any update notice as informational and direct the user to external administration.

If no compatible installation is found, the connection attempt ends before opening the main bridge. The diagnostic should show the host, detected platform, discovered Herdr path/version if any, the required endpoint generation, and a link to the official installation or upgrade documentation. It should not offer a one-tap fix or transmit an installation command.

This boundary reduces App Review ambiguity and removes a large remote supply-chain and process-disruption surface. It does not remove the need to audit the Herdr-derived client code embedded in the app.

## 12. App Store release strategy

The architecture is designed to address the relevant review rules, not to guarantee approval.

### Technical posture

- Every component executed on iOS is precompiled and included in the signed app bundle.
- The app uses public iOS APIs.
- No JIT, downloaded dynamic code, locally executed remote binary, or post-review feature code is used.
- The app does not provision software on the remote host; it only invokes an independently installed Herdr executable selected during the compatibility probe.
- The app's purpose remains a user-directed SSH client; Herdr is a remote system the user elects to access.
- Remote commands and plug-ins execute on the user's remote machine.
- Background behavior is finite and tied to clean disconnect/recovery.
- The app works on IPv6-only networks.

These points map most directly to [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 2.5.1, 2.5.2, 2.5.4, and 2.5.5. Also review 2.3.1 for complete disclosure, 4.2 for minimum functionality, 5.2.1 for intellectual-property rights, and 5.2.2 when displaying or integrating third-party services. Guideline 4.2.7 contains special rules for remote-desktop clients; a terminal/SSH integration is materially different from a generic remote-desktop mirror, but the submission notes should describe the architecture precisely and counsel should review the current wording at release time.

### Review package

Provide App Review with:

- A short architecture explanation distinguishing signed local client code from remote command execution.
- Exact steps to reach the feature.
- A time-limited demo SSH account/host with Herdr preinstalled, or a realistic offline demo mode when providing a live account is unsafe.
- Instructions for host-key acceptance and any local-network prompt.
- A sample workflow demonstrating connect, local text paste, image paste, background/foreground reconnect, and disconnect.
- A statement that the app never downloads or executes Herdr on iOS and never downloads, uploads, installs, or updates Herdr on the remote host.
- Contact information able to answer technical review questions promptly.

### Privacy and export compliance

Complete App Store privacy disclosures from actual behavior, including every bundled SDK. Apple requires a privacy-policy URL and disclosure of app and third-party data practices; see [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).

SSH uses encryption, so answer App Store Connect export-compliance questions accurately. Whether the app qualifies for an exemption or requires documentation depends on the encryption implementation, distribution regions, and app facts. Keep an export-classification memo, dependency/algorithm list, and any annual self-classification records with the release. Start with Apple's [export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and [encryption documentation reference](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/), then obtain specialist advice for the final binary.

## 13. Licensing and attribution plan

### 13.1 Herdr's current license

At v0.9.0, Herdr still declares `Apache-2.0` in its Cargo manifest ([Cargo manifest](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/Cargo.toml#L1-L51)) and includes the [Apache License 2.0 text](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/LICENSE). The changelog records a relicensing to Apache-2.0 in version 0.8.0 ([relicensing entry](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/CHANGELOG.md)). Multi-machine support does not introduce a different top-level license. Pinning the exact source revision matters; do not assume an older checkout or future release has identical terms. The newly included endpoint coordinator/state code must join the same modification ledger and target-specific dependency audit as the existing protocol core.

Apache-2.0 is generally compatible with proprietary App Store distribution when its conditions are met. In practical terms, for the Herdr-derived portion:

- Include a copy of the Apache-2.0 license with the distributed app.
- Retain copyright, patent, trademark, and attribution notices from source files.
- Clearly mark files that the project modifies.
- Include relevant contents of any upstream `NOTICE` file if one exists and applies. No root `NOTICE` file was present in the reviewed commit, but this must be checked on every update.
- Do not imply that the license grants the right to use Herdr's names, logos, or marks as the app's brand; Apache-2.0 expressly does not grant trademark rights. Use a descriptive phrase such as “Connect to Herdr” and seek permission before using a Herdr logo or naming the app as though it were official.

Read and preserve the exact obligations in the [official Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0.html).

### 13.2 Vendored and transitive code

The root license is not the whole audit. The reviewed tree includes, among other dependencies:

- A vendored Ghostty terminal library under the [MIT license](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/vendor/libghostty-vt/LICENSE), with its source revision recorded in [`libghostty-vt.vendor.json`](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/vendor/libghostty-vt.vendor.json) and local patches recorded in [`libghostty-vt.patches.md`](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/vendor/libghostty-vt.patches.md).
- Vendored `portable-pty` under its [MIT license](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/vendor/portable-pty/LICENSE.md).
- Rust dependencies listed in the [Cargo manifest](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/Cargo.toml#L17-L51), plus their transitive dependencies.
- The app's SSH stack and its transitive cryptography/networking dependencies.
- Any fonts, icons, sounds, fixtures, or images copied from Herdr or other projects.

If Option A extracts only protocol and state code, many desktop dependencies and vendored assets should not enter the iOS dependency graph. That is a strong reason to keep the new crates minimal. If Option B links Ghostty or more of the desktop client, inspect every nested vendor directory and file header; a simple search for files named `LICENSE` is not a complete audit.

Because the app will not distribute a remote Herdr executable, no remote-platform release archive should appear in the app bundle or download cache. That narrows the distribution audit, but it does not eliminate the Apache-2.0 obligations for Herdr-derived protocol/client code compiled into the iOS binary.

### 13.3 Reproducible compliance workflow

For every release candidate:

1. Pin Herdr by tag and full Git commit; archive the source URL and source archive hash.
2. Resolve Cargo dependencies for the exact device and simulator targets that ship, with the production feature set. Do not treat the all-platform `Cargo.lock` as proof of what is in the app.
3. Run [`cargo-deny`](https://embarkstudios.github.io/cargo-deny/) license, advisory, ban, and source checks with an explicit SPDX allowlist and individually documented exceptions.
4. Generate the human-readable attribution bundle with [`cargo-about`](https://embarkstudios.github.io/cargo-about/), whose documented workflow includes `cargo about init` and `cargo about generate`.
5. Produce an equivalent Swift Package Manager dependency and license inventory.
6. Review vendored/native assets and build scripts manually; automated Cargo tools cannot classify every copied file, custom exception, or trademark issue.
7. Have a human confirm the final linked binary's dependency set and all license texts.
8. Display acknowledgements in Settings and ship a machine-readable `THIRD_PARTY_NOTICES` file in the app bundle or support package.
9. Maintain a modification ledger that identifies the upstream file, commit, local change, reason, and local owner.
10. Archive the SBOM, notices, source manifest, tool output, and legal approval with the exact App Store build number.

Neither `cargo-deny` nor `cargo-about` provides legal advice or replaces review of ambiguous licenses. Configure CI to fail on unknown, unlicensed, disallowed, or unexpectedly sourced packages rather than silently omitting them.

### 13.4 Suggested acknowledgement entry

The final text must be generated from the actual shipped source, but the Herdr entry will likely resemble:

```text
Herdr
Copyright (c) the Herdr contributors
Licensed under the Apache License, Version 2.0.
This product contains software derived from Herdr and includes modifications
for an embedded iOS client transport and user interface.

[full Apache-2.0 license text follows]
```

Use exact upstream copyright wording if provided. Add separate entries for each included dependency as required by its license.

## 14. Delivery plan

### Phase 0 — upstream and legal alignment

- Open an issue/design proposal with Herdr maintainers for the reusable protocol/client crates.
- Confirm the intended third-party compatibility guarantee for endpoint generation 1.
- Ask about permission for descriptive name/logo use and preferred attribution.
- Pin a baseline commit and complete an initial license/provenance review.
- Record preinstallation and external remote maintenance as a permanent product invariant.

**Exit:** written protocol direction, approved branding language, and no unresolved license blocker in the proposed minimal graph.

### Phase 1 — transport spike

- Implement a non-PTY exec channel using the existing SSH engine.
- Run `remote-client-bridge` on a test host.
- Keep stderr separate and demonstrate lossless binary round trips.
- Build a fake transport for deterministic tests.
- Add two independent preprovisioned endpoints, including different sessions on one host, and prove that one failed/stalled connection does not block the other.

**Exit:** a macOS or iOS test harness completes a stable endpoint handshake and receives a snapshot without spawning local `ssh` or `herdr` processes.

### Phase 2 — reusable core and Apple build

- Extract protocol, surface-state, selection, and interaction-router code into library crates.
- Include the endpoint registry/supervisor, message policy, and activation reducer while removing desktop Local-server and SSH-process assumptions.
- Define the C ABI and build device/simulator static libraries.
- Package an XCFramework and integrate it with the iOS build.
- Add golden vectors for every supported message plus selection, keyboard, pointer, pixel-geometry, graphics, and compatibility fixtures for multiple Herdr releases.
- Add decoder and FFI fuzzing.

**Exit:** identical fixtures pass on macOS, simulator, and a physical iPad; no desktop-only module is linked.

### Phase 3 — local UI and input

- Add the Herdr structured-surface provider to the existing terminal emulator without sending Herdr frames through its normal VT parser.
- Render shell/workspace snapshots and patches, including graphemes, wide cells, styles, cursor shape, hyperlinks, scroll metadata, popup surfaces, and ordered graphics scenes.
- Implement pane focus, resizing, server-authoritative selection, external keyboard shortcuts, hardware-key press/repeat/release, IME/composition, complete left/right/middle mouse routing, SGR pixel mouse, continuous/discrete scrolling, and touch gestures.
- Handle Split View, Stage Manager, orientation, dynamic type, VoiceOver, and reduced motion.
- Add machine/session navigation, combined agent rows, stale/Attention states, and transactional surface switching with endpoint-qualified actions.

**Exit:** the same terminal renderer passes ordinary SSH and structured Herdr surface fixtures, routine Herdr navigation works with touch and a physical mouse/keyboard, and the session is accessible with VoiceOver.

### Phase 4 — clipboard and device features

- Add server-authoritative text selection/copy, explicit semantic text paste, and opt-in remote OSC 52 clipboard writes.
- Add bounded, normalized image paste with metadata policy.
- Add local notifications only for events that are available while the app is active unless a separately reviewed push architecture exists.
- Add privacy controls and per-host settings.
- Test copy, asynchronous image paste, pointer capture, title/graphics effects and notification activation while switching or reconnecting machines.

**Exit:** clipboard tests pass at empty, normal, malformed, and maximum-size boundaries without content leakage.

### Phase 5 — lifecycle, compatibility, and release hardening

- Implement suspend/detach/reconnect behavior.
- Test hostile/malformed servers, network transitions, server restarts, and version mismatches.
- Complete SBOM, notices, export compliance, privacy labels, accessibility audit, review demo, and reviewer notes.
- Run TestFlight on physical iPads across supported iOS versions and network types.

**Exit:** the release checklist below is signed off against the exact archived build.

## 15. Acceptance and release checklist

### Functional

- [ ] Password, public-key, passphrase-protected-key, and hardware-backed-key flows work where supported.
- [ ] New, known, and changed host keys behave correctly.
- [ ] Non-default ports, IPv6 literals, DNS names, and configured jump hosts work.
- [ ] The channel is non-PTY and stdout is never text-normalized.
- [ ] Missing or incompatible Herdr produces diagnostics only; it never triggers download, upload, installation, update, or replacement.
- [ ] Endpoint generation and codecs are negotiated rather than assumed.
- [ ] Named sessions are correctly quoted and isolated.
- [ ] Full snapshot, incremental patch, focus, resize, and shutdown paths work.
- [ ] Multiple clients and focus/ownership transitions behave correctly.
- [ ] Remote server restart and local network loss produce understandable recovery.
- [ ] iPad background/foreground reconnect preserves the remote workspace.

### Multi-machine support (v0.9.0)

- [ ] At least two remote hosts and two named sessions on one host can be represented without merging their state.
- [ ] Add Machine never invokes upstream installation-capable setup; missing/incompatible endpoints remain diagnostic-only.
- [ ] Every endpoint negotiates generation/codecs and the full surface-interest, presentation-fence, surface-set-method and health requirements independently.
- [ ] Missing optional methods disable only their endpoint's affected action; a single incompatible host does not reject the whole client.
- [ ] Colliding workspace/tab/pane IDs and agent names route correctly; labels can change without changing profile identity.
- [ ] Inactive endpoints update agent/workspace metadata and attributed notifications without pane-screen streaming or local clipboard/title/graphics/input-mode effects.
- [ ] Switching freezes input until source deactivation, coherent target snapshot/surface/current geometry, and presentation synchronization complete.
- [ ] Rapid A→B→C switching, failed target activation, cancellation, server restart, and late responses never send keys/paste to the wrong host.
- [ ] Held modifiers, mouse down/drag/up, selection copy, and asynchronous image paste remain machine-qualified through switching and reconnect.
- [ ] Independent bounded writes/health/retries and aggregate memory limits are tested with one flooded endpoint, one stalled endpoint, and one healthy interactive endpoint.
- [ ] Reconnect does not steal selection; stale cached panes remain visibly stale and noninteractive until refreshed.
- [ ] Disable/remove disconnects only the chosen profile, preserves remote processes, and returns the iPad to a neutral view if necessary.
- [ ] Multiple clients on different tabs preserve independent views; clients on one shared tab follow last-interaction resize ownership.
- [ ] Background/foreground recovery is tested for several endpoints without an unsupported keepalive/background mode or a reconnect storm.

### Terminal rendering and input

- [ ] Herdr structured surfaces bypass the normal VT parser and render through the emulator's surface-provider abstraction.
- [ ] Full frames and patches enforce endpoint boot, projection, base, and resulting surface revisions.
- [ ] Grapheme clusters, combining marks, emoji sequences, wide cells, skip/tail cells, and non-US text render without recomputing incompatible widths.
- [ ] Indexed/default/true color, every Herdr style bit, cursor visibility/shape/blink, alternate-screen state, and hyperlink metadata render correctly.
- [ ] Graphics tests cover RGB, RGBA, PNG, source cropping, offsets, clipping, z-order, scrolling, resize, cache reuse, replacement, and retirement.
- [ ] OSC 8 links require an explicit safe open action and do not steal clicks intended for a mouse-reporting application.
- [ ] Window title, bell, toast, sound, and semantic notifications follow local user settings.
- [ ] Hardware keyboard tests cover press, repeat, release, supported modifiers, character/function/navigation/editing keys, Kitty keyboard modes, and `ClientShellKeyboardReportAll`.
- [ ] Unsupported keypad, media, Caps Lock, and HID keys are ignored or handled locally rather than serialized as incorrect terminal keys.
- [ ] Software keyboard and IME tests cover marked versus committed text, dead keys, emoji, CJK input, and absence of duplicate character delivery.
- [ ] Scene focus transitions and cell/pixel resizes reach the remote terminal in the correct order.

### Mouse, trackpad, and touch

- [ ] Left, middle, and right down/drag/up sequences retain their original pane/popup destination through motion, surface changes, and cancellation.
- [ ] Hover/moved events are forwarded only when required by the pane's application mouse mode; local chrome hover remains independent.
- [ ] Right-click obeys the pane passthrough and configured-modifier policy and otherwise opens the correct Herdr context menu.
- [ ] Vertical and horizontal wheel input works for discrete mice and continuous trackpads without double scrolling.
- [ ] Wheel routing covers application mouse reports, alternate-screen scrolling, and host scrollback.
- [ ] Pane focus, drag selection, selection autoscroll, double-click word selection, scrollbars, split handles, tabs, and Ctrl-click hyperlinks work.
- [ ] SGR pixel mouse uses 1-based pane coordinates and exact matching cell/pixel geometry across Split View, Stage Manager, external displays, rotation, and fractional scaling.
- [ ] Pixel mode downgrades safely to cell coordinates during resize or whenever exact geometry is unavailable.
- [ ] UIKit gesture and `GCMouseInput` sources are deduplicated so one physical action produces one ordered Herdr event sequence.
- [ ] Auxiliary mouse buttons are ignored or handled locally until Herdr advertises a compatible protocol capability.
- [ ] Touch defaults to selection/navigation; any application-mouse translation is an explicit session mode.

### Clipboard and media

- [ ] Pasteboard reads occur only after clear user intent.
- [ ] Selection copy uses `pane.selection.read` and is correct across soft wraps, scrollback, wide graphemes, concurrent output, and content-revision mismatch.
- [ ] Empty, multiline, bracketed, non-ASCII, and very large text pastes are tested.
- [ ] Text paste is a semantic `Paste` event and is never double-wrapped in bracketed-paste sequences.
- [ ] Paste into local Herdr overlays remains local and cannot leak into the remote pane.
- [ ] Remote clipboard writes are bounded, attributed, and user controlled.
- [ ] Image paste tests cover supported formats, corrupt files, decompression bombs, EXIF removal, focus changes, and the 16 MiB boundary.
- [ ] Clipboard/terminal content never appears in logs, analytics, or crash metadata.

### Security and robustness

- [ ] Frame sizes, queues, render dimensions, patches, and allocations are bounded.
- [ ] Malformed and truncated messages fail closed.
- [ ] Decoder, patch engine, image handling, and FFI are fuzzed.
- [ ] Private keys and secrets remain protected by Keychain/data-protection policy.
- [ ] Command construction has injection test vectors.
- [ ] Agent forwarding and unnecessary SSH features are disabled by default.
- [ ] Security review covers remote-server compromise, not only network attackers.

### iOS quality

- [ ] Physical-device tests cover supported iPadOS versions.
- [ ] IPv6-only, LAN permission denied/allowed, Wi-Fi/cellular handoff, VPN, and captive-network cases are tested.
- [ ] Split View, Stage Manager, external display, rotation, memory pressure, thermal throttling, and low-power mode are exercised.
- [ ] VoiceOver, Dynamic Type, switch control, pointer, hardware keyboard, and IME behavior are reviewed.
- [ ] No unsupported background mode or private API is present.

### Licensing and store submission

- [ ] Herdr tag, commit, source hash, and locally modified files are recorded.
- [ ] Target-specific Rust and Swift dependency inventories are archived.
- [ ] All bundled source/assets have an identified license and required attribution.
- [ ] Apache-2.0 and every required third-party license are visible in acknowledgements.
- [ ] No upstream `NOTICE` or file-level notice has been omitted.
- [ ] App name, screenshots, text, and icons do not imply official Herdr endorsement.
- [ ] App privacy answers match the binary and server behavior.
- [ ] Encryption/export-compliance answers and supporting records are complete.
- [ ] App Review has a functioning demo path and precise architecture notes.

## 16. Principal risks and decisions still required

| Risk or decision | Why it matters | Recommended disposition |
|---|---|---|
| Stable endpoint is not yet a separately published SDK | The iOS app may lag remote server releases | Obtain upstream support and conformance fixtures; pin a tested compatibility range |
| Rust-specific `bincode` wire format | Independent clients can drift with enum/type changes | Reuse upstream Rust codec; do not hand-code Swift serialization |
| Full client vs. minimal core | Changes UI effort, binary size, and license surface | Extract the smallest protocol/state/interaction core that preserves selection and mouse routing; keep visual controls native |
| Structured surface integration | Converting Herdr frames back to ANSI would lose metadata and create a second terminal state machine | Add a terminal surface-provider interface next to the existing VT parser |
| Multi-machine routing and switching | Reused IDs or stale activation/copy responses could target the wrong host | Endpoint-qualified identity, frozen input, coherent surface activation and presentation fences |
| Multi-machine resource/failure isolation | One noisy or unreachable host can otherwise exhaust memory or stall all input | Independent bounded transports/supervisors plus aggregate mobile budgets |
| Desktop Local endpoint assumptions | Upstream fallback behavior may accidentally require an iPad server or select an unintended host | Explicit remote-only home/unavailable state and per-scene selection |
| Auxiliary mouse buttons | Herdr generation 1 represents only left, right, and middle | Ignore or use locally until upstream adds a negotiated capability; do not alter the frozen enum |
| Extended hardware keys | The stable key enum does not separately represent keypad, media, Caps Lock, or arbitrary HID keys | Map only exact supported semantics and request an upstream negotiated extension for anything else |
| Remote version management | Client/server compatibility can change while the app cannot repair the remote host | Treat installation and updates as external administration; detect and explain incompatibility only |
| Background session expectations | iOS cannot promise an indefinitely live SSH connection | Detach on background; reconnect to persistent remote server |
| Remote clipboard control | A compromised host can overwrite or exfiltrate clipboard data | Explicit local gestures, bounded data, host attribution, opt-in writes |
| Herdr branding | Open-source copyright license does not grant trademark rights | Descriptive integration wording; request permission for logos/official branding |
| Dependency/license drift | A future update can add a new obligation or incompatible license | Target-resolved CI audit plus human review on every upgrade |
| App Review interpretation | Remote-computing rules and review outcomes can change | Recheck current guidelines and provide a transparent review package for each release |

## 17. Final recommendation

Proceed with a prototype, but define the product as an **embedded Herdr remote client**, not “Herdr running as a downloaded command-line program on iPad.” Every release should:

- Link a minimal, audited Rust endpoint/client core into the signed app.
- Reuse the existing SSH engine for an independently supervised non-PTY `remote-client-bridge` exec channel per enabled machine/session endpoint.
- Aggregate metadata locally, namespace every target by endpoint identity, and switch the selected surface through a validated activation transaction.
- Connect Herdr's structured surface model directly to the existing terminal renderer through a dedicated provider rather than replaying it as ANSI.
- Include the client interaction reducer needed for server-authoritative selection, semantic keyboard/paste, full left/right/middle mouse routing, SGR pixel coordinates, scroll routing, and graphics scenes.
- Require a compatible, independently managed Herdr installation on the remote host and never install or update it from the app.
- Implement server-authoritative local selection/copy and semantic text paste first, followed by tightly bounded image paste.
- Disconnect cleanly in the background and reconnect to the persistent remote server.
- Ship complete Apache-2.0 and transitive acknowledgements based on the exact target-resolved binary.
- Use Herdr's name descriptively and coordinate the reusable-core work with upstream.

This approach captures the user benefit—native iPad keyboard, selection, copy, paste, and image workflows—without crossing the critical App Store line into downloading or executing new code on iOS.

## Primary references

- [Herdr repository](https://github.com/herdrdev/herdr)
- [Herdr v0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0)
- [v0.9.0 connecting-machines guide](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/connecting-machines.mdx)
- [Endpoint catalog and registry source](https://github.com/herdrdev/herdr/tree/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/client/endpoint)
- [Attach-only saved SSH source](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/remote/saved.rs)
- [Reviewed Herdr source commit](https://github.com/herdrdev/herdr/tree/b99002ac99b09e00b4ca692436cb15a6b0d676f1)
- [Herdr remote-mode documentation](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/persistence-remote.mdx)
- [Herdr stable endpoint definitions](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/endpoint.rs#L1-L77)
- [Herdr wire protocol and limits](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/protocol/wire.rs#L1-L35)
- [Herdr Apache-2.0 license](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/LICENSE)
- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0.html)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Apple app privacy guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Apple local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple physical-keyboard event handling](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard)
- [Apple `UITextInput`](https://developer.apple.com/documentation/uikit/uitextinput)
- [Apple `UIPasteControl`](https://developer.apple.com/documentation/uikit/uipastecontrol)
- [Apple `UIHoverGestureRecognizer`](https://developer.apple.com/documentation/uikit/uihovergesturerecognizer)
- [Apple `GCMouseInput`](https://developer.apple.com/documentation/gamecontroller/gcmouseinput)
- [Apple `UIScrollType`](https://developer.apple.com/documentation/uikit/uiscrolltype)
- [Rust Apple iOS platform support](https://doc.rust-lang.org/rustc/platform-support/apple-ios.html)
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)
- [`cargo-deny` documentation](https://embarkstudios.github.io/cargo-deny/)
- [`cargo-about` documentation](https://embarkstudios.github.io/cargo-about/)
