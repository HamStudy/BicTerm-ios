# App Review notes — BicTerm (Herdr remote terminal client)

Task T20. Supporting notes for App Store review. These are factual
statements about the shipped binary and demo path; they make no claim about
review outcomes.

## Architecture statement

BicTerm is a **locally executed, signed terminal client**. It is an SSH
client (SwiftNIO SSH) with an embedded, compiled-in Herdr endpoint client
core (Rust, statically linked as HerdrCore.xcframework, Apache-2.0).

- All executable code in the app is compiled into the signed binary at
  build time. **The app never downloads, interprets, or executes code on
  iOS.**
- **The app's only remote install action is the consent-gated herdr
  installer described below.** It never replaces or upgrades an existing
  Herdr and never installs any other software: a preflight probe checks
  whether a compatible Herdr endpoint already exists on the user's own
  server; when no binary exists the app may offer the pinned install, and
  a present-but-incompatible Herdr is a diagnostic with a link to the
  upstream project, never an in-app upgrade.
- Remote workspaces run on the user's own machines. The iPad renders
  server-computed terminal surfaces (a cell grid over the existing SSH
  channel) and forwards keyboard/paste input — remote display and input,
  not remote code execution on the device.
- No JIT, no plugin runtime, no scripting interpreter, no dynamically
  loaded native code, no background modes beyond the standard audio-free
  set (none declared), no private APIs (verified by the AppStore-flavor
  three-layer audit: build system, bundle + `otool`, `strings` sweep).
- Networking is user-initiated: connections go only to hosts the user
  configures, over SSH (port 22 or user-configured), with
  trust-on-first-use host-key verification and Keychain-stored credentials.

## Reviewer demo path

1. Launch BicTerm. The connection list appears ("No connections yet" until
   one is added). Tap **+** to add a connection (host, port, username,
   key-based auth).
2. A demo host must be provisioned by the developer before submission
   (see below); connect to it and the terminal workspace renders.
3. Without any Herdr on the host, the app still functions as a plain SSH
   terminal. Opening the Herdr surface against a host with no herdr
   binary offers the consent-gated install (see "Remote herdr install"
   below); declining quietly stops the bring-up, like a declined
   host-key prompt. A present-but-incompatible Herdr shows the
   diagnostic-only screen ("Incompatible Herdr on the host") — that case
   is never remediated in-app.
4. Settings → Acknowledgements shows the full third-party notices
   (Apache-2.0 and all required licenses).

Demo host provisioning is an action item for the app owner before
submission: provide a reachable SSH host with a compatible `herdr`
endpoint installed, plus a reviewer account. Record its address and
credentials in App Store Connect's review notes; nothing in-app hardcodes
or ships it.

## Remote herdr install (consent-gated)

When the preflight probe finds NO herdr binary on an otherwise-supported
host (Linux or macOS, x86_64 or aarch64), the app can offer to install
the pinned herdr 0.9.0 CLI onto that host. Facts for review:

- **What it does**: downloads the pinned herdr 0.9.0 release binary for
  the host's platform and copies it to `$HOME/.local/bin/herdr` on the
  host, over the user's own authenticated SSH connection (the same
  connection the terminal session uses — no separate channel, no
  credentials beyond it).
- **Consent model**: an explicit prompt naming the host, the version, the
  destination, and the download source appears on EVERY qualifying
  connect. Approval is never persisted and there is no "always allow";
  declining is a quiet no-op. The prompt text states that nothing is
  elevated and nothing else on the host is changed.
- **Integrity**: the download URL and a per-target SHA-256 are committed
  in the app's source (`HerdrReleasePins`, sourced from the upstream
  v0.9.0 release manifest). The downloaded bytes are verified against
  the pin before they are ever sent to the host — checked on download
  and re-verified before upload.
- **Scope**: missing-binary only. The app never replaces or upgrades an
  existing herdr — a present-but-incompatible binary stays a diagnostic.
  No privilege elevation (no sudo/su/doas), no package managers, no
  pipe-to-shell: the remote side only receives the app's own
  prepare/stream/chmod/mv script sequence, mirroring upstream herdr's
  own desktop install mechanism.

## Data handling (App Privacy answers)

- No analytics, no telemetry, no crash reporting services, no tracking.
- Clipboard access occurs only after explicit user gestures (paste/copy
  buttons); reads are counted in debug builds and asserted zero before
  gestures in the test suite.
- Credentials: SSH keys and passwords live in the iOS Keychain
  (data protection, this-device-only for passwords). Host-key trust
  decisions are local. The herdr per-host clipboard opt-in is a local
  boolean; no terminal or clipboard content is ever logged (enforced by an
  automated source audit).

## Contact

App owner: <repository owner>. Contact email must be filled in
before submission: `TODO(app-owner): contact email for App Review`.

## Out-of-scope honesty notes

- This document does not predict or claim App Store approval; it states
  what the binary does and how to exercise it.
- The binary contains no AGPL/GPL code anywhere in its dependency graph
  (see `DEPENDENCIES.md`). The Herdr core is Apache-2.0.
