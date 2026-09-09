# A22 native active-session rebuild

Command: `bash scripts/test-coder-rebuild.sh`

The native test establishes a live CoderTransport session and executes a
command before requesting a workspace rebuild. A bounded host-side watcher
updates the owned g12-rebuild workspace and replaces its actual agent process.

Results in `phase2-g12-b-rebuild-tests.log` (one test, zero failures):

- The original output stream finishes after replacement.
- Fresh resolution returns a different agent UUID.
- Explicit resolution of the previous UUID is rejected.
- A new CoderTransport connection executes on the rebuilt workspace.

`phase2-g12-b-rebuild-agent.log` records the real rebuild and connected-agent
snapshot. `phase2-g12-b-rebuild-native.log` includes initial provisioning and
the complete test invocation. No production code changed for this row.

Shell syntax checks passed. SourceKit could not resolve XCTest; Xcode compiled
and ran the test successfully. Shell LSP is unavailable and was not installed.
Final full-suite runs must arrange the rebuild watcher alongside this test;
the request/ready markers are reset by the wrapper on each invocation.

A19-A21 and A34 remain incomplete. This is row evidence, not phase approval.
