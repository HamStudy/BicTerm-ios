# A32 concurrent native profile isolation

Command: `bash scripts/test-coder-profiles.sh`

`phase2-g12-b-profile-native.log` records two distinct, authenticated,
non-administrator users and two connected agents. Each user receives HTTP 200
for its own agent connection endpoint and HTTP 404 for the other user's agent.
Both permissions are checked against the real Coder deployment before the
Swift test runs.

The native Swift test creates two CoderTransport instances in one process,
using separate profile credentials and the production C bridge. It connects
both concurrently, reads each workspace's agent-provided environment value,
and asserts that neither output stream contains the other workspace's result.
The expected workspace name is not embedded in the sent shell command.
After closing the first transport, the second successfully executes another
command and returns its own workspace value.

Results:

- Native isolation test: one passed, zero failures, in
  `phase2-g12-b-profile-tests.log`.
- Shared fixture helper regression: four native selection tests passed in
  `phase2-g12-b-profile-selection-regression.log`.
- Ruby and shell syntax checks passed. Swift LSP reported unresolved CoderNet
  and XCTest modules; Xcode compiled and executed the tests successfully.
  Ruby and shell LSP servers are unavailable; no installation was performed.

The owned profiles and agents remain available for final full-suite runs.
Their credentials are in the ignored repository-local
`Fixtures/run/coder-acceptance/profiles.json`, created with mode 0600, not in
evidence or command arguments. Fixture preparation reuses those owned profiles.

No production transport change was needed for this row. A19-A22 and A34 still
block the phase gate. This is executed row evidence, not phase approval.
