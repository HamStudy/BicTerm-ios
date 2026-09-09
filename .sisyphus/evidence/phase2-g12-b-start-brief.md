# Batch B start slice: A07, A08, A09 PASS

## Executed commands

From the repository root with `source scripts/env-local-caches.sh` and the
repository-local HOME/cache overrides used by the wrapper:

```sh
bash scripts/test-coder-start.sh
DEST_OVERRIDE='platform=iOS Simulator,id=732CE8E1-F9EF-4020-BF93-5BA1AA365B0E' DERIVED_DATA="$PWD/.build-artifacts/DerivedData/g12-core" ONLY_TESTING='BicTermCoreTests/CoderNativeStartPolicyAcceptanceTests' EVIDENCE_LOG='.sisyphus/evidence/phase2-g12-b-start-disabled.log' scripts/test-core.sh
```

The app-unit wrapper prepares independent stopped workspaces, then starts a
repository-local agent-script watcher and invokes only
`BicTermTests/CoderNativeStartAcceptanceTests` on the canonical iPhone.
The watcher observes atomic script replacement after real builds, starts
the new agents, and terminates its owned child process groups on exit.

## Assertions and results

- A07: actual stopped workspace, explicit false policy, reconnectRequired,
  native ledger `GET, GET`, no mutation. One Core test passed.
- A08: exactly one native start POST returning 201, starter ready state,
  connected/ready agent with a different ID from the stopped generation.
- A09: real accepted POST response is dropped by the request-loader boundary;
  next event is the authoritative workspace GET; total POST count remains one.
  Readiness succeeds with the new agent, proving no duplicate blind mutation.
- Both app-unit cases passed (2 tests, 0 failures). No client production
  behavior needed alteration for these rows; only native fixture/test wiring.

## Evidence index

- `phase2-g12-b-start-native.log`: initial native app-unit run and full ledger.
- `phase2-g12-b-start-acceptance.log`: final wrapper rerun, 2/2 green.
- `phase2-g12-b-start-agent-ledger.log`: watcher ready, one main agent per
  workspace started, watcher stopped.
- `phase2-g12-b-start-disabled.log`: real Core disabled-policy case, 1/1 green.
- `phase2-g12-b-start-matrix.log`: matrix structure and verifier tests.

The before-stop snapshots are generated under
`Fixtures/run/coder-acceptance/{g12-start-explicit,g12-start-lost}/before-stop.json`.
The wrapper recreates these preconditions each run; run it rather than calling
the stateful native app-unit cases without fixture preparation.

All test/harness files are below 250 pure lines. Standalone SourceKit may lack
app/package context; actual xcodebuild execution is authoritative. Shell/Ruby
syntax checks pass. No UI source or protected dirty tests were changed.

Matrix: PASS=22, FAIL=9, NOT-LOCAL=3. Remaining rows are A10-A12, A19-A22,
A32 and A34. This checkpoint does not authorize phase-gate approval.
