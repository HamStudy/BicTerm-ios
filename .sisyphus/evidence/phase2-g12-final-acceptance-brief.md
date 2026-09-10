# T12 final native acceptance verification

Date: 2026-09-09

The acceptance matrix now records 31 PASS, zero FAIL, and three NOT-LOCAL
rows. This is execution evidence for Atlas's approval decision; the plan
checkbox remains unchanged and no Herdr work is authorized by this report.

## Final verification

- `bash scripts/test-coder-core-final.sh iphone`: 328 tests, zero failures,
  15 existing environment-dependent skips.
- `bash scripts/test-coder-core-final.sh ipad`: 328 tests, zero failures,
  the same 15 existing skips.
- Both runs include the live Coder conformance, startup, profile isolation,
  coordinator recovery, and active-session rebuild tests. The wrapper resets
  held-script markers and starts the required control proxy/rebuild watcher.
- Full Go suite: `go test -C CoderNet -race -shuffle=on -count=1 ./...` passed.
- Device and simulator CoderNet XCFramework slices rebuilt successfully.
- Native app lifecycle-action tests and explicit-start/startup-policy
  regressions passed; their individual briefs retain exact results.
- Previously accepted UI work and its committed evidence were not redone.

Evidence: `phase2-g12-final-core-iphone.log`,
`phase2-g12-final-core-ipad.log`, `phase2-g12-b-derpmap-go-regression.log`,
and `phase2-g12-b-derpmap-xcframework.log`.

## A34 logging audit

`ruby scripts/audit-coder-logs.rb` scans all T12 log/document artifacts under
the evidence tree, including nested logs. It checks actual user credentials,
captured native resume tokens, fixture private-key material, and unique
terminal markers exercised by the live control-recovery tests. Raw, URL-encoded,
and base64 forms are checked. Each pattern has an in-memory positive control,
and a benign diagnostic has a negative control. Private-key headers and
JWT-shaped values are also rejected.

Native bridge callbacks are captured during the live scenario. Their output
is nonempty and excludes the terminal marker. Audit inputs remain in ignored,
repository-local fixture files; secret values are not printed in the report.
The audit excludes its own two output files to avoid self-referential hashes.

Results and exact scanned-file SHA-256 manifest:
`phase2-g12-final-log-audit.log` and `phase2-g12-final-log-audit.json`.
This is a concrete sentinel audit, not a claim that arbitrary future logging
changes cannot leak data.

## Limits retained

- A18 remains needs-private-CA, an optional authorized live-deployment check.
- A28/A29 remain scope-explained v1 exclusions, not optional live checks.
- Existing Core skips concern unavailable simulator entitlements/hardware or
  alternate fixture modes; no skips were added to obtain these results.
- SourceKit cannot resolve some test modules. Xcode builds and test execution
  provide compiler verification. New Go files have clean LSP diagnostics.
- Ruby/shell LSP servers and gofumpt/golangci-lint are unavailable. Ruby/shell
  syntax checks, gofmt checks, Go race tests, and whitespace checks were used;
  no tooling was installed.
- Protected test files and governing specifications remain untouched.
