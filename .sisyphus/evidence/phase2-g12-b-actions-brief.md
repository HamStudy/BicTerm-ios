# A10 native lifecycle and parameter gates

Date: 2026-09-09

Command: `bash scripts/test-coder-actions.sh`

The fixture provisions a dedicated `bicterm-actions` template and two owned
workspaces. It stops both, marks one dormant through the native API, and gives
the other automatic updates plus a new required parameter without a default.
The preparation script verifies native dormancy and `parameter_mismatch=true`
before tests begin. These are not simulated API responses.

## Red and green evidence

`phase2-g12-b-actions-red.log` records the dormant attempt issuing a POST.
The native server cleared dormant_at and changed the build from stopped to
starting. The parameter-mismatch attempt already refused correctly.

`CoderWorkspaceStarter.start` now fetches current workspace detail before its
parameter gate and refuses dormant workspaces with an explicit reactivation
instruction. The existing UI dormancy screen remains unchanged. This places
the refusal at the service boundary too, rather than relying solely on the
earlier UI read.

`phase2-g12-b-actions-green.log` records two passing native tests:

- Dormant: GET/GET/GET, zero start POSTs, "Workspace is dormant", unchanged
  workspace detail.
- Parameter mismatch: GET/GET/GET/GET, zero start POSTs, "Startup parameters
  required", unchanged workspace detail.

Fixture setup deliberately mutates owned fixtures. The read-only assertions
cover the subsequent BicTerm connection-preparation attempts, not setup.

## Regressions

- `phase2-g12-b-actions-start-regression.log`: explicit start and accepted
  response-loss recheck, two tests passed.
- `phase2-g12-b-actions-policy-regression.log`: blocking/nonblocking explicit
  starts, two tests passed.
- `phase2-g12-b-actions-unit-regression.log`: existing start-policy unit test
  passed.
- `ruby -c scripts/prepare-coder-actions.rb` and
  `bash -n scripts/test-coder-actions.sh` passed.
- Starter LSP diagnostics were clean. The new Swift test's LSP could not
  resolve BicTermCore; successful Xcode builds provide compiler verification.
  Ruby and shell LSP servers are unavailable; none was installed.

No UI view, protected file, plan checkbox, or verifier was modified. A19-A22,
A32, and A34 remain outstanding, as do final full-device regressions and the
phase gate. This evidence is not phase approval.
