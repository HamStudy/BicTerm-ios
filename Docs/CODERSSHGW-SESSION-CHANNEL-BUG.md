# Bug report: CoderSSHGW 0.5.0 permits only one session channel per connection lifetime

## Summary

CoderSSHGW 0.5.0 permits exactly one session channel per SSH connection over the connection's entire lifetime. A second session channel, even after the first has been cleanly closed (SSH_MSG_CHANNEL_CLOSE in both directions), is rejected with SSH_OPEN_ADMINISTRATIVELY_PROHIBITED (reason code 1) and the description string:

```
workspace connections permit one session channel
```

The connection, authentication, and the first session channel all work normally. Only the second channel open fails.

## Reproduction with stock OpenSSH

No custom tooling is required:

```
ssh -o ControlMaster=yes -o ControlPath=/tmp/coder-ctl -o ControlPersist=120 <user>@<gateway-host> 'echo ONE'
ssh -o ControlPath=/tmp/coder-ctl <user>@<gateway-host> 'echo TWO'
```

Observed behavior:

- The first command prints `ONE`: the channel opens, the exec runs, the channel closes cleanly.
- The second command emits `mux_client_request_session: session request failed: Session open refused by peer` on the multiplexed connection. OpenSSH then silently falls back to a fresh direct TCP connection, which succeeds.

Note: this fallback means most OpenSSH users never notice the bug. Clients that reuse connections without a fallback path (Paramiko, libssh, SwiftNIO SSH, Jsch, or ControlMaster setups requiring a shared connection) hard-fail.

## Second independent data point

A SwiftNIO SSH client (BicTerm, an iOS terminal app) against `coder.ham.dev`:

- Auth via RSA publickey (YubiKey PIV through ssh-agent) succeeds.
- The first session channel (interactive shell or exec) opens and works.
- The second session channel open on the same connection is rejected. Captured verbatim from the client:

```
NIOSSHError.channelSetupRejected: Reason: 1 workspace connections permit one session channel
```

Two independent clients (OpenSSH and SwiftNIO SSH) reproduce identical behavior, so this is a server-side policy, not a client bug.

## Why this violates SSH semantics

- RFC 4254 section 5 defines channels as SSH's multiplexing primitive. A connection is explicitly designed to carry multiple simultaneous channels: "Either side may open a channel. Multiple channels may be multiplexed into a single connection." Port forwarding, agent forwarding, X11 forwarding, and multiple sessions all assume this.
- OpenSSH sshd's `MaxSessions` (default 10) limits concurrent session channels per connection, and a closed channel's slot is immediately reusable. A lifetime-total-of-one rule has no analogue in any mainstream SSH server.
- Standard client behavior that breaks under this rule:
  - ControlMaster connection reuse: any ControlMaster user running a second command.
  - SFTP plus shell coexistence on one connection.
  - Git over SSH with connection reuse.
  - IDE remote tooling: VS Code Remote opens multiple channels.
  - Any client that probes a connection before use.

## Environment where observed

- Server banner: `SSH-2.0-CoderSSHGW_0.5.0`
- Workspace connections (username = workspace name)
- Publickey authentication
- Evidence captured on an iPad running BicTerm and reproduced on macOS with stock OpenSSH
- First channel works perfectly: connection, auth, and first channel are all healthy. Only the second session channel open is refused.

## Requested fix

Allow multiple concurrent session channels per connection. A small concurrent cap such as `MaxSessions=10` is perfectly fine and matches OpenSSH behavior. At minimum, always permit a new channel once the previous one has closed.

If the one-channel rule is an intentional security or resource boundary for workspace connections, please document it and return a distinct, documented failure code. Note that even documented, it will still break standard SSH tooling, so lifting it is strongly preferred.

## Impact

BicTerm's remote-tooling flow needs two channels per machine: a short probe exec, then a long-lived bridge exec. An interactive terminal plus a background exec is the same shape. The app is implementing a connection-per-channel workaround, but that costs a full extra TCP and SSH handshake plus authentication per channel, including biometric prompts on Secure Enclave keys and repeated password prompts. This is a poor user experience that the gateway can eliminate by conforming to standard channel semantics.
