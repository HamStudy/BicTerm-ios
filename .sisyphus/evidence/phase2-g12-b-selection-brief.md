# Batch B selection slice: A04, A05, A06 PASS

Command: `bash scripts/test-coder-selection.sh` from the repository root.
The script sources repository-local caches, provisions the native two-agent
fixture, records old identities, rebuilds it, waits for connected replacement
agents, and runs CoderNativeSelectionAcceptanceTests on the canonical iPhone.

Outcome: four tests passed, zero failures. This includes four actual transport
connections (main and sidecar, each by exact name and UUID), automatic-ambiguity
rejection, unknown-UUID/no-name-fallback rejection, and real old-build UUID
rejection. Each successful connection reads the agent-specific environment
marker, avoiding false positives from terminal input echo.

## Root causes fixed

- Core transport ignored saved agent name/UUID options. The native red test
  failed with reconnectRequired on an explicit selection. Core now parses
  the selector and matches only current-build agents; UUID takes precedence.
- A dynamic Terraform map made each script resource depend on both agents,
  causing Coder's job-completion transaction to reject duplicate agent names.
  Explicit per-agent references fixed the native fixture association.
- The fixture retained old agent processes after rebuild, which kept retrying
  rejected credentials (HTTP 401). The helper now stops its old owned agents
  before launching the regenerated scripts.
- The pinned CLI's update command has no --yes option; its actual help is
  retained and the helper uses the supported invocation.

## Evidence

All paths below are in `.sisyphus/evidence/`:
- `phase2-g12-b-selection-fixture.log`: duplicate-name fixture failure.
- `phase2-g12-b-selection-fixture-green.log`: unsupported update flag attempt.
- `phase2-g12-b-update-help.log`: pinned CLI contract.
- `phase2-g12-b-selection-fixture-ready.log`: corrected fixture provisioning.
- `phase2-g12-b-selection-behavior-red.log`: ignored explicit selector.
- `phase2-g12-b-selection-green.log`: initial three-test green result.
- `phase2-g12-b-selection-rebuild-readiness.log`: stale processes leave new agents created.
- `phase2-g12-b-selection-wrapper-final.log`: complete reproducible setup/build/test execution.
- `phase2-g12-b-selection-previous.log`, `phase2-g12-b-selection-current.log`: public before/after identities.
- `phase2-g12-b-selection-acceptance.log`: final four-test green result.
- `phase2-g12-b-resolver-regression.log`: existing resolver tests stay green.
- `phase2-g12-b-selection-matrix.log`: structural verifier and its tests pass.

The template also declares startup variants needed by later rows. Those rows
are not marked PASS merely because the declarations exist.

Source sizes: resolver 102 pure lines, transport 249, fixture support 79,
selection tests 81; template and scripts below 250. The transport is at the
warning boundary: further additions must extract the touched responsibility
rather than grow this file. SourceKit cannot resolve standalone package/test
modules; authoritative xcodebuild compilation and execution passed. Bash,
Ruby and Terraform LSP servers are unavailable; shell/Ruby syntax checks and
real Terraform provisioning were used without installing dependencies.

Matrix after this slice: PASS=19, FAIL=12, NOT-LOCAL=3. No UI source or
protected dirty file was modified. Phase approval remains blocked.
