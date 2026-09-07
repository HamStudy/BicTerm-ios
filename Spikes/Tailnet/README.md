# Coder Tailnet Feasibility Spike

This is Task 20 gate evidence, not a Coder tunnel implementation. It proves that
Swift can decode the relevant `AgentConnectionInfo` subset and perform an
authenticated coordinate WebSocket upgrade against a deterministic loopback
fixture. It does not modify or link BicTerm production targets.

## Reproduce

From the repository root:

```sh
Spikes/Tailnet/Scripts/run-coordinate-spike.sh
Spikes/Tailnet/Scripts/check-wireguardkit.sh
```

The scripts are rerunnable, fail when required evidence is absent, and redirect
controllable home, temporary, module-cache, SwiftPM, build, compiler, fixture,
and log output to these repository-local locations:

- `Spikes/Tailnet/.build/`
- `.scratch/task-20/`
- `.build-artifacts/task-20/`
- `.sisyphus/evidence/task-20-*.log`

No dependency fetch is needed for the coordinate spike. The WireGuardKit script
does not fetch upstream code: it first compiles and links a real
`NEPacketTunnelProvider` subclass against the iOS Simulator SDK, then attempts
to compile/link a program importing `WireGuardKit` and referencing
`TunnelConfiguration`. A project-local module can be supplied with
`WIREGUARDKIT_SEARCH_PATH`; external paths are rejected.

## What the coordinate proof means

Coder's coordinate WebSocket is a **binary byte stream**, not JSON-per-frame.
After HTTP upgrade, a compatible client still needs, in order:

1. yamux stream multiplexing over the WebSocket byte stream;
2. dRPC framing and service semantics;
3. generated protobuf messages from Coder's tailnet service schema;
4. coordinate-node lifecycle, peer authorization, key exchange, and updates;
5. WireGuard packet handling and peer configuration;
6. Tailscale-compatible DISCO, endpoint discovery, STUN, magicsock path
   selection, NAT traversal, and rebinding behavior for direct paths;
7. a DERP client, including authentication and framing, to relay already
   encrypted WireGuard packets when direct paths are disabled or unavailable;
8. an in-process TCP endpoint usable by the existing SSH transport.

The fixture returns one binary frame only to prove binary delivery. It does not
claim that the bytes are a valid yamux session or that any layer after the
WebSocket upgrade interoperates.

## WireGuardKit constraints

WireGuardKit configures ordinary WireGuard through a packet-tunnel/utun
boundary. It does not provide any Coder or Tailscale control-plane layer listed
above, and upstream WireGuard Apple requires manual `wireguard-go-bridge`
integration. A deployable iOS packet tunnel also requires:

- a Network Extension target and Packet Tunnel Provider entitlement;
- physical-device testing (the Simulator is only useful for compile/link and
  limited API checks, not evidence of a real packet tunnel or utun behavior);
- explicit user approval of the VPN configuration, with visible system VPN
  state and lifecycle consequences;
- provisioning/profile support and Apple App Review scrutiny for VPN behavior.

Task 20 deliberately adds no entitlement and no production extension target.

## Source and license boundary

Protocol facts were checked against Coder commit
`92642e6913cf3e08edde6fdff9c3f3251d4f1296`, its pinned Coder Tailscale fork
commit `e42b84be7a30`, Tailscale commit
`5201273aec737d6372ab7423c31c04ca3ca2a0c2`, and WireGuard Apple commit
`2fec12a6e1f6e3460b6ee483aa00ad29cddadab1` at the paths listed in the Task 20
plan. Coder is AGPL-3.0; Tailscale DERP/tailcfg is BSD-3-Clause; WireGuard Apple
is MIT. This spike copies no upstream implementation. Any future copied schema,
generated protobuf, or implementation work requires legal review, especially
at the Coder AGPL boundary.
