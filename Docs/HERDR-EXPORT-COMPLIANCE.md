# Export compliance memo — BicTerm encryption usage

Task T20. **DRAFT for the app owner's review; not legal advice.** The owner
must confirm classification and file the definitive answers in
App Store Connect before submission.

## What the app ships

BicTerm uses encryption exclusively for authenticated, encrypted transport
sessions to servers the user configures:

1. **SSH-2 protocol** (RFC 4251-4254) via the vendored swift-nio-ssh:
   key exchange (curve25519-sha256, diffie-hellman groups), host-key
   signatures (ed25519, RSA, ECDSA), AEAD ciphers (AES-GCM,
   chacha20-poly1305), HMAC families. Purpose: remote login security.
2. **Herdr endpoint channel**: application messages carried inside the same
   SSH channel (no additional cryptographic layer; the embedded Rust core
   adds no crypto beyond SHA-256 hashing for fingerprints/identity).
3. **Platform crypto** via Apple frameworks (Security framework, Keychain,
   Secure Enclave for P-256 keys, crypto-Kit where used) for at-rest
   protection of credentials and trust decisions.

No proprietary or custom cryptography is implemented. No export-controlled
"open cryptanalysis" functionality exists. Keys are user-generated or
platform-generated; the app does not distribute keys or crypto products to
third parties.

## Proposed classification (draft)

- **ECCN 5D002** (software for encryption software/infrastructure) is the
  conservative classification for an SSH client implementation.
- The standard SSH-client posture qualifies for **License Exception ENC —
  mass market** under 740.17(b)(1): generally available to the public,
  standard cryptographic algorithms (AES, SHA-2, RSA/ECC), interoperative
  end-to-end with an open standard, not designed or customized for
  military/end-government use.
- Equivalent postures exist in other jurisdictions (e.g. the EU dual-use
  regulation's mass-market/encryption-for-authentication carve-outs); the
  owner should confirm per distribution region.

## App Store Connect answers (draft)

- `ITSAppUsesNonExemptEncryption = NO` — the app exclusively uses standard
  encryption for SSH transport and platform Keychain protection, which
  qualifies for exemption; standard yearly self-classification reporting
  obligations under 740.17(e) may still apply and are the owner's to track.
- France declarations and other national filings: none known for a
  mass-market SSH client; owner to confirm.

## Records

- Binary composition: App Store flavor build (see
  `Docs/SECURITY.md`, T7 audit logs) — links swift-nio-ssh (Apache-2.0),
  SwiftTerm (MIT), Swift standard libraries, and the statically linked
  Herdr Rust core (Apache-2.0; `sha2` is its only cryptography-adjacent
  crate, used for fingerprints).
- SBOM for the Rust core with build number:
  `.sisyphus/evidence/phase2-h20-sbom-*` (cargo-deny + cargo-audit +
  Cargo.lock snapshot).

## Changes that retrigger this review

Any new dependency implementing cryptography, any new transport protocol,
any change from key-based to other credential handling, or distribution in
a new jurisdiction.
