# BicTerm patch — swift-nio-ssh agent forwarding

Vendored fork of [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh),
tag **0.15.0** (commit `3ec281496f28a3b6581afd946b759e2642f5cd8d`), Apache-2.0
(LICENSE.txt retained verbatim).

## Why this fork exists

BicTerm's in-app SSH agent (plan task T8) requires OpenSSH agent forwarding
(PROTOCOL.agent). Upstream 0.15.0 cannot do it:

- **Outbound**: sending the `auth-agent-req@openssh.com` channel request hits
  the `default:` of `SSHChildChannel._actuallyTriggerOutboundEvent0` and fails
  with `ChannelError.operationUnsupported` (upstream line 427).
- **Inbound**: an `auth-agent@openssh.com` channel open hits the `default:` of
  `ByteBuffer.readChannelOpenMessage()` and throws
  `NIOSSHError.unknownPacketType` (upstream lines 905-906), which tears down
  the entire SSH connection.

Every deviation from upstream is marked inline with a `BICTERM-PATCH hunk N`
comment so the fork can be diffed and re-based mechanically. No upstream
behavior is changed beyond the additions below; no other request or channel
types were enabled.

## Hunks

### Sources/NIOSSH/SSHMessages.swift

1. `SSHMessage.ChannelOpenMessage.ChannelType`: added `case authAgent`.
2. `readChannelOpenMessage()`: parse `"auth-agent@openssh.com"` → `.authAgent`
   (no type-specific payload, per PROTOCOL.agent).
3. `writeChannelOpenMessage()` (name switch): serialize `.authAgent` →
   `"auth-agent@openssh.com"`.
4. `writeChannelOpenMessage()` (payload switch): `.authAgent` writes no
   payload.
5. `SSHMessage.ChannelRequestMessage.RequestType`: added `case authAgentReq`.
6. (a) `readChannelRequestMessage()`: parse `"auth-agent-req@openssh.com"` →
   `.authAgentReq` (no payload).
   (b) `writeChannelRequestMessage()` (name switch): serialize `.authAgentReq`.
   (c) `writeChannelRequestMessage()` (payload switch): no payload.

### Sources/NIOSSH/Child Channels/SSHChannelType.swift

7. Public `SSHChannelType`: added `case authAgent` (Equatable, Sendable — no
   associated values).
8. `SSHChannelType.init(_ message: ChannelOpenMessage)`: map `.authAgent`.
9. `ChannelOpenMessage.ChannelType.init(_ type: SSHChannelType)`: reverse map
   (exhaustiveness; clients never originate this channel type).

### Sources/NIOSSH/Child Channels/ChildChannelUserEvents.swift

10. (a) `SSHChannelRequestEvent.AgentForwardingRequest` — new public
    `Hashable, Sendable` struct with a single `wantReply: Bool` field.
    (b) `SSHMessage.init(_:recipientChannel:)` overload converting the event
    to a `.channelRequest(.authAgentReq)` message.
11. `SSHChannelRequestEvent.fromMessage`: `.authAgentReq` returns `nil` —
    a client never legitimately receives this request; the existing
    `handleInboundChannelRequest` fallback replies `SSH_MSG_CHANNEL_FAILURE`
    when wantReply is set.

### Sources/NIOSSH/Child Channels/SSHChildChannel.swift

12. `_actuallyTriggerOutboundEvent0`: `AgentForwardingRequest` events are
    converted to wire messages (previously `default:` →
    `ChannelError.operationUnsupported`).

## Usage notes

- OpenSSH's own client sends `auth-agent-req@openssh.com` with
  `wantReply = false` and treats denial as non-fatal; consumers should do the
  same (no reply event is generated, so no success/failure tracking needed).
- `SSHChannelType.authAgent` channels are delivered through the existing
  `inboundChildChannelInitializer` mechanism; a `nil` initializer still
  **accepts** them (upstream fallback), so clients that do not support agent
  forwarding must keep an explicit reject/routing initializer.

## Maintenance

Re-basing onto a future upstream release: re-apply hunks 1-12 (all additive
enum cases plus three small switch arms), keep `BICTERM-PATCH` markers, and
re-verify that upstream's parse/serialize switch positions have not gained
conflicting cases. An upstream PR for first-class agent-forwarding support is
a candidate; if accepted and released, this fork can be retired.
