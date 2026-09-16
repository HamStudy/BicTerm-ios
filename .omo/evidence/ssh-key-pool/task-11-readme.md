# T11 README read-through (ssh-key-pool)

Date: 2026-09-15. Base: HEAD 9ccf0c7 (T1-T10 committed, rebased onto origin/main).
Scope: docs-only. Files touched: README.md and this artifact. No source, Vendor/,
fork/patch docs, Docs/, or herdr docs changed.

## What was changed

README.md, "What Works" bullet 1, rewritten for the pool model:

- **SSH connections with a key availability pool**: every key you enable (ed25519 from Keychain, P-256 from Secure Enclave) is offered automatically on each connect attempt, the way an SSH agent works. The server picks from what it is offered; there is no per-connection key selection by default. A connection's **Customize** section can narrow the offer to an explicit set of keys, and switching **Offer Keys** off skips keys entirely. Passwords are decoupled from key selection: save a password connection blank to be prompted during connect or reconnect (RFC 4252 `password` only), and a saved or prompted password still completes authentication when the server rejects every key or requires both factors. The prompt can remember destination passwords in this device's Keychain, protected when locked and never transferred to another device; jump-host prompts are session-only (save hop passwords in the editor instead). Connection rows summarize the destination's offer as **All keys (N offered)**, **N selected keys**, or **Password**, and the editor verifies the local Keychain entry before showing **Saved on this device**. Herdr connections authenticate through the same SSH layer.

README.md, "What Works" bullet 2 (key management), updated:

- **Key management with per-key switches**: generate or import an SSH key, or copy a public key, directly from the connection editor's key picker; the picker reads the Keychain live and auto-selects a freshly saved key. The Key Management screen gives every key an on/off switch that controls whether it joins the default offer, and a warning appears once more than five keys are enabled (many servers allow only six authentication attempts, OpenSSH's default `MaxAuthTries 6`, and may disconnect before later keys are tried). The Settings hardware-keys default affects only the pool a connection inherits; a key you explicitly select in Customize always applies.

README.md, "What's Not In Scope (v1)", two lines added:

- PIV / USB-C hardware-token support (deliberately deferred; the Settings hardware-keys toggle is the only forward-hook)
- A second system sshd fixture for password testing (UI password tests use the in-process test server on port 18090)

"RSA keys / key export" was already listed under Not In Scope and stays unchanged.

## What was removed

The stale sentence "Connection rows show **Password** or the authentication **key label**" is gone from the first bullet. T10 replaced that row subtitle with resolver-computed summaries; the rewritten bullet now states them ("All keys (N offered)" / "N selected keys" / "Password").

## What was verified (read-through)

- Pool model is the default: all enabled keys offered automatically, no per-connection key selection by default.
- Per-connection Customize is the editor's explicit key-picking section; Offer Keys off skips keys entirely.
- Passwords are decoupled from key selection; saved-blank prompting and remembered destination passwords keep their original semantics; hop prompts stay session-only.
- Herdr is mentioned only as authenticating through the same SSH layer; no herdr-specific auth claims.
- The >5 warning rationale cites OpenSSH MaxAuthTries 6.
- The hardware-default setting is scoped to the inherited pool only; explicit Customize selection always applies.
- Row summaries match T9's resolver-computed subtitles.
- No fork/patch docs touched; no herdr docs touched; no source files touched.

## Acceptance gates

Gate 1: grep -n "Offer Keys\|offered" README.md (must match):
17:- **SSH connections with a key availability pool**: every key you enable (ed25519 from Keychain, P-256 from Secure Enclave) is offered automatically on each connect attempt, the way an SSH agent works. The server picks from what it is offered; there is no per-connection key selection by default. A connection's **Customize** section can narrow the offer to an explicit set of keys, and switching **Offer Keys** off skips keys entirely. Passwords are decoupled from key selection: save a password connection blank to be prompted during connect or reconnect (RFC 4252 `password` only), and a saved or prompted password still completes authentication when the server rejects every key or requires both factors. The prompt can remember destination passwords in this device's Keychain, protected when locked and never transferred to another device; jump-host prompts are session-only (save hop passwords in the editor instead). Connection rows summarize the destination's offer as **All keys (N offered)**, **N selected keys**, or **Password**, and the editor verifies the local Keychain entry before showing **Saved on this device**. Herdr connections authenticate through the same SSH layer.
```

Gate 2: ! grep -n "or the authentication" README.md (must find NOTHING):

```
(no output; grep exit status 1)
```

Both gates passed before this artifact was built and before the commit.

DOC-PASS
