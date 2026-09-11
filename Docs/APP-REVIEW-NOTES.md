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
- **The app never installs, updates, uploads, or replaces Herdr (or any
  other software) on the remote host.** A preflight probe checks whether a
  compatible Herdr endpoint already exists on the user's own server and
  renders a diagnostic when it does not; remediation is documented as an
  out-of-app administrative action (a link to the upstream project), never
  an in-app action.
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
   terminal. Opening the Herdr surface against an incompatible host shows
   the diagnostic-only screen ("No Herdr found on the host" / "Incompatible
   Herdr on the host") — the boundary behavior reviewers should see:
   diagnostics only, never installation.
4. Settings → Acknowledgements shows the full third-party notices
   (Apache-2.0 and all required licenses).

Demo host provisioning is an action item for the app owner before
submission: provide a reachable SSH host with a compatible `herdr`
endpoint installed, plus a reviewer account. Record its address and
credentials in App Store Connect's review notes; nothing in-app hardcodes
or ships it.

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

App owner: Richard (repository owner). Contact email must be filled in
before submission: `TODO(app-owner): contact email for App Review`.

## Out-of-scope honesty notes

- This document does not predict or claim App Store approval; it states
  what the binary does and how to exercise it.
- The dual-build flavor note: the App Store flavor contains no AGPL code
  (the Coder tunnel core is excluded at build time; audited per release).
  The Herdr core is Apache-2.0 and ships in both flavors.
