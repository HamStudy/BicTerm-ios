# Adding a terminal protocol

This is the executable recipe for adding a remote-session protocol to
BicTermCore. The protocol seam is intentionally byte-oriented: session and UI
code consume capabilities and never import a protocol's wire types. The
in-memory Uppercase Echo implementation in the test target follows this recipe
and is kept as a third-conformer proof.

## 1. Implement `TerminalTransport`

Start with the contract in
[TerminalTransport.swift](../BicTermCore/Sources/BicTermCore/Transport/TerminalTransport.swift)
and map all wire/library errors to
[TransportError.swift](../BicTermCore/Sources/BicTermCore/Transport/TransportError.swift).
Implement every requirement below; do not leak a library error or channel type
through the public API.

- **Isolation and identity.** The conformer must be an actor (or provide
  equivalent synchronization) and satisfy `Sendable` plus `AnyObject`. One
  instance represents one connection attempt. The session layer relies on
  object identity while bridging output.
- **Output.** `output` is an `AsyncStream<Data>` created fresh for the
  instance, using `bufferingNewest` with a bound of 32. It has one consumer.
  Finish it on a remote terminal drop and on `close()`. A native-roaming
  transport must keep the same stream open while suspended.
- **Connect.** `connect(to:cols:rows:)` performs transport setup,
  authentication, PTY/session creation, and initial sizing for the supplied
  `Connection`. Reject the wrong protocol type with
  `protocolUnavailable(protocolID:)`; map reachability, trust, authentication,
  and channel failures to `TransportError`. A failed or repeated connection
  attempt must not leave live resources behind.
- **Input and backpressure.** `send(_:)` writes bytes only while connected and
  throws `channelDenied` before connect, during suspension, and after close.
  It is async so wire flow control suspends the caller instead of growing an
  unbounded queue. `pipe(input:)` already forwards an `AsyncStream<Data>`
  producer through that suspending path; do not create a second input
  continuation.
- **Resize.** `resize(cols:rows:)` forwards positive dimensions after connect.
  Ignore zero, negative, suspended, or closed requests. The method is
  fire-and-forget; no protocol acknowledgment may block the session actor.
- **Suspend and resume.** `resumeStrategy` is `rehandshake` when backgrounding
  tears down the connection. The default `suspend()` calls `close()` and the
  default `resume()` throws `resumeUnsupported`. A roaming protocol declares
  `nativeRoaming`: suspend preserves its server-side session and output stream,
  and resume reattaches the same instance without another connect or
  authentication attempt. A failed native resume throws a typed
  `TransportError`.
- **Close.** `close()` is terminal and idempotent. It releases channels,
  sockets, tasks, and continuations; finishes output exactly once; and makes
  later sends fail with `channelDenied`.

Finally implement `TerminalTransportFactory`. Its `makeTransport(for:)` must
return a fresh conformer only when the selected type matches and otherwise
throw `protocolUnavailable(protocolID:)`. Keep protocol-specific dependencies
behind this factory.

## 2. Register a `ProtocolDescriptor`

Read
[ProtocolDescriptor.swift](../BicTermCore/Sources/BicTermCore/Transport/ProtocolDescriptor.swift)
and
[TransportRegistry.swift](../BicTermCore/Sources/BicTermCore/Transport/TransportRegistry.swift).
Add one descriptor next to the implemented transport, then call
`register(_:factory:)` on `TransportRegistry` in the composition root.

Each field is a promise, not advertising:

- `id` is stable persisted data and exactly matches the selected
  `ConnectionType` raw value.
- `displayName` is user-facing.
- `supportsAgentForwarding` is true only if the final remote shell can use the
  BicTerm agent. Merely authenticating a bootstrap SSH connection with a key
  does not count.
- `supportsJumpChain` is true only if both bootstrap and protocol data paths
  honor `Connection.jumpChain`.
- `supportsRoamingResume` must be equivalent to
  `resumeStrategy == .nativeRoaming`; the conformance suite checks this.
- `requiresServerComponent` drives the installation/status hint.
- `defaultPort` is the value placed in a new connection. Explain whether it is
  a bootstrap or data port when the protocol uses both.
- `keyAlgorithmsAccepted` lists authentication key algorithms actually
  accepted by the complete connection path.

### Eternal Terminal descriptor draft

**DRAFT ONLY — do not register until the ET transport and its tests exist.**

```swift
extension ProtocolDescriptor {
    static let et = ProtocolDescriptor(
        id: "et",
        displayName: "Eternal Terminal",
        supportsAgentForwarding: false,
        supportsJumpChain: true,
        supportsRoamingResume: true,
        requiresServerComponent: true,
        defaultPort: 2022,
        keyAlgorithmsAccepted: ["ssh-ed25519", "ecdsa-sha2-nistp256"],
        resumeStrategy: .nativeRoaming
    )
}
```

Reasoning: the [swift-et research candidate](https://github.com/wiedymi/swift-et)
documents a TCP ET data connection on port 2022, SSH bootstrap injection,
jumphost support, reconnect/resume, and application-background checkpoints.
The draft therefore promises native roaming, jump chains, and a required
etserver. Keep agent forwarding **false**: bootstrap SSH may use BicTerm's key
for authentication, but that does not expose an agent socket inside the final
ET shell. Change it to true only after that distinct end-to-end behavior is
implemented and tested. If the eventual adapter cannot route both bootstrap
and ET data through the selected jump chain, lower the jump flag before
shipping. Store a non-default SSH bootstrap port as a protocol option because
the descriptor's default is the ET data port.

### mosh descriptor draft

**DRAFT ONLY — do not register or add a dependency until the clean-room and
license gates in section 7 pass.**

```swift
extension ProtocolDescriptor {
    static let mosh = ProtocolDescriptor(
        id: "mosh",
        displayName: "Mosh",
        supportsAgentForwarding: false,
        supportsJumpChain: false,
        supportsRoamingResume: true,
        requiresServerComponent: true,
        defaultPort: 22,
        keyAlgorithmsAccepted: ["ssh-ed25519", "ecdsa-sha2-nistp256"],
        resumeStrategy: .nativeRoaming
    )
}
```

Reasoning: mosh uses SSH only to authenticate and launch mosh-server, then
closes SSH and moves the terminal to a directly reachable UDP port (normally
60000–61000). Thus port 22 is the bootstrap default, the UDP port/range belongs
in protocol options, and an SSH jump does not tunnel the UDP session. The
final shell has neither SSH agent forwarding nor SSH port forwarding. Roaming
is native and mosh-server is required.

## 3. Add the connection type and protocol options

In
[Connection.swift](../BicTermCore/Sources/BicTermCore/Models/Connection.swift),
add a stable case to `ConnectionType`. Its raw value must equal descriptor
`id`; never rename a shipped raw value. Update the model round-trip test. The
Uppercase Echo proof's `uppercaseEcho` case demonstrates the exact persistence
and registry path without registering a production factory.

```swift
public enum ConnectionType: String, Codable, Equatable, Hashable, Sendable {
    case ssh
    case coder
    case et
    case mosh
}
```

`ConnectionType` is a closed Codable enum. Add the case before writing that
value to storage. A known case whose factory is absent is handled by
`TransportRegistry` as `protocolUnavailable(protocolID:)`; a completely
unknown raw value cannot decode far enough to reach the registry.

Use `protocolOptions` for non-secret, protocol-specific values. The container
in
[ProtocolOptions.swift](../BicTermCore/Sources/BicTermCore/Models/ProtocolOptions.swift)
accepts only `ProtocolOptionValue` strings, integers, and booleans. Prefix keys
with the protocol ID, document defaults, validate ranges in the factory, and
test encode/decode. For example:

```swift
let etOptions = try ProtocolOptions([
    "et.bootstrapPort": .int(22),
    "et.serverFIFO": .string("/tmp/etserver.fifo"),
])
let moshOptions = try ProtocolOptions([
    "mosh.udpPortLow": .int(60_000),
    "mosh.udpPortHigh": .int(61_000),
])
```

Never put passwords, passphrases, private keys, tokens, session keys, or ET
passkeys in protocol options. The validator rejects secret-bearing key names;
credentials belong in Keychain and are referenced through `keyReference`.

## 4. Run the conformance suite

Use
[TransportConformanceSuite.swift](../BicTermCore/Tests/BicTermCoreTests/Transport/TransportConformanceSuite.swift)
as the behavioral contract and
[FakeTransportConformanceTests.swift](../BicTermCore/Tests/BicTermCoreTests/Transport/FakeTransportConformanceTests.swift)
as the in-memory wiring example. `TransportConformanceScript` provides common
latency, connect-failure, and resume-failure scenarios. A real network
implementation may map those scenarios onto a controllable fixture instead of
accepting the script itself.

Create one XCTestCase for the conformer and forward all eight identically named
tests to `TransportConformanceSuite`:

- `testConnectSucceedsAndOutputStreamIsLive`
- `testInputOutputRoundTrip`
- `testResizeIsObserved`
- `testSuspendResumeFollowsDeclaredStrategy`
- `testResumeFailureSurfacesTypedTransportError`
- `testCloseIsTerminalIdempotentAndFinishesOutput`
- `testSendBeforeConnectThrowsTypedChannelDenied`
- `testConnectFailureSurfacesTypedTransportError`

For `nativeRoaming`, provide both hardened hooks:

1. a resume-failing transport/fixture whose expected error is a
   `TransportError`; and
2. a `RoamingResumeObservation` read from the implementation's bootstrap
   boundary. Its connect/authentication counts must remain unchanged while its
   resume count increases exactly once. This proves that suspend/resume did not
   conceal a fresh login. Verify I/O through the same output stream afterward.

Run a future ET conformer with this exact command (change only the test class,
derived-data suffix, and evidence filename for another protocol):

```sh
DEST_OVERRIDE='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.3.1' \
DERIVED_DATA=.build-artifacts/DerivedData/et-conformance \
ONLY_TESTING=BicTermCoreTests/ETTransportConformanceTests \
EVIDENCE_LOG=.sisyphus/evidence/et-transport-conformance.log \
scripts/test-core.sh
```

The executable guide proof is itself reproducible exactly:

```sh
DEST_OVERRIDE='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.3.1' \
DERIVED_DATA=.build-artifacts/DerivedData/t15-proof \
ONLY_TESTING=BicTermCoreTests/ExtensionGuideProofTests \
EVIDENCE_LOG=.sisyphus/evidence/task-15-extension-proof.log \
scripts/test-core.sh
```

`ExtensionGuideProofTests` creates `UppercaseEchoTransport`, registers its
descriptor/factory, round-trips its `Connection` through Codable, resolves it
through `TransportRegistry`, and runs all shared lifecycle and error tests.

## 5. Extend fixtures with one block

Follow the one-block convention in
[Fixtures/README.md](../Fixtures/README.md) and the existing numbered sections
in [fixtures-up.sh](../scripts/fixtures-up.sh). Keep the in-memory conformance
class fast, then add a second fixture-backed class for wire interoperability.
Add exactly one directory under Fixtures for the protocol and one coherent
block following this pattern:

```sh
# ---- future protocol block -----------------------------------------------
FUTURE_PIDFILE="$RUN/future.pid"
if [ -f "$FUTURE_PIDFILE" ] && kill -0 "$(<"$FUTURE_PIDFILE")" 2>/dev/null; then
  : # already running
else
  future-server --listen 127.0.0.1 --port "$FUTURE_PORT" \
    </dev/null >>"$RUN/future.log" 2>&1 &
  echo $! > "$FUTURE_PIDFILE"
  disown 2>/dev/null || true
fi

# Add its PID to the existing pids manifest, then in the existing sections:
wait_port "$FUTURE_PORT" future
check "future protocol round trip" "expected" "$actual"
```

The real block must:

1. bind loopback only and use committed fake credentials;
2. be idempotent, with its PID and log under Fixtures/run;
3. append its PID to the existing manifest so the current teardown consumes it;
4. wait for readiness and run a loud protocol-level self-check; and
5. add one README section naming ports, files, environment knobs, and tests.

For ET, wait on the TCP data port and prove bootstrap plus reconnect against a
real compatible server. For mosh, do not use a TCP port probe for the data
path: reserve a loopback UDP range, launch through SSH, and make the self-check
exchange an authenticated datagram and terminal state. Never run fixture
teardown while another test agent owns the shared fixtures.

## 6. Verify capability-driven UI (normally no UI code change)

If the descriptor is truthful and the UI consumes registry capabilities,
there is nothing protocol-specific to add. Verify this checklist rather than
adding protocol-name branches:

- the picker lists the registered `displayName` and uses `defaultPort` for a
  new connection;
- the server-component hint appears exactly when
  `requiresServerComponent` is true;
- the agent-forwarding control appears/enables only when
  `supportsAgentForwarding` is true;
- jump-chain editing appears/enables only when `supportsJumpChain` is true;
- background/foreground behavior follows `resumeStrategy`, with no SSH-shaped
  reconnect forced on `nativeRoaming`;
- key selection is filtered by `keyAlgorithmsAccepted`;
- a known but unregistered type presents the typed unavailable state and never
  silently falls back to SSH; and
- protocol options render from metadata/defaults without exposing secrets.

A failed item means fix the descriptor or the shared capability consumer. Do
not add an ET/mosh special case to session or terminal code.

## 7. Pass the license and provenance gate

BicTerm is an App Store product with a GPL/LGPL-free dependency policy; review
[DEPENDENCIES.md](../DEPENDENCIES.md) before adding any package or vendored
source.

- Record the exact version/revision, source URL, license, notices, transitive
  graph, review date, and App Store verdict for every new dependency.
- Verify the license from the exact revision, not a repository badge. The
  current swift-et candidate declares
  [MIT](https://github.com/wiedymi/swift-et/blob/main/LICENSE), while Eternal
  Terminal itself declares
  [Apache-2.0](https://github.com/MisterTea/EternalTerminal/blob/master/LICENSE).
- **Mosh trap:** upstream mosh is
  [GPL-3.0](https://github.com/mobile-shell/mosh/blob/master/COPYING). Do not
  link, vendor, translate, port, paste, or derive BicTerm client code from its
  implementation. Blink/mosh code is pattern reference only and supplies no
  reusable artifact.
- A future mosh client must have a documented clean-room boundary: approved
  protocol inputs, independent authorship/provenance records, black-box
  interoperability vectors, and legal review before code enters the product.
  The protocol paper and public behavior may be usable inputs only after that
  review. The existence of the independent
  [MIT mosh-go implementation](https://github.com/unixshells/mosh-go) is a
  clean-reimplementation precedent, not permission to copy either it or GPL
  mosh without a dependency/provenance review.
- Keep GPL tools/servers outside the shipped app and test whether generated
  fixtures, vectors, or copied protocol constants carry provenance concerns.
- Re-run the dependency audit and the full core suite. A missing license,
  unclear origin, or GPL-derived artifact is a stop-ship result, not a TODO.

The descriptor drafts above are documentation only. They do not authorize a
dependency, register ET or mosh, or relax this gate.
