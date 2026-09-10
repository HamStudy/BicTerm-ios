# Modification ledger

Baseline: `b99002ac99b09e00b4ca692436cb15a6b0d676f1` (v0.9.0).
Local owner: BicTerm task 13.

| Local path | Upstream path | Change | Reason |
| --- | --- | --- | --- |
| `LICENSE` | `LICENSE` | None; exact archived copy | Preserve upstream license |
| `.gitignore` | None | New local file | Keep reference checkout, source tar, and build output out of commits |
| `UPSTREAM_SOURCE.sha256` | Entire pinned tree | New archive digest record | Reproducible source provenance |
| `PROVENANCE.md` | None | New local record | Source/toolchain provenance and explicit incomplete audit status |
| `EXTRACTION_ESCALATION.md` | Referenced source locations | New boundary assessment | Preserve exact unresolved extraction work without publishing partial APIs |
| `UPSTREAM_PROPOSAL.md` | None | Unsubmitted discussion draft | Respect upstream contribution policy while recording the client-library use case |

No upstream Rust file was modified. The ignored boundary probe copies
`src/protocol/{wire,endpoint}.rs`, `src/client/endpoint.rs`, and
`src/client/endpoint/` unchanged. Its small local manifest/module harness is
diagnostic only and must not be distributed as `herdr-client-core`.

Extraction has not landed. Every future copied/modified shipping source
file must receive its own mapping and change rationale; this ledger does not
preapprove omissions or changes to frozen wire fields/enum order.
