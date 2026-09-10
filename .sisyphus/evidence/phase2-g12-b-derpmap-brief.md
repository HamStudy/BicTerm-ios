# A19 native dynamic DERP map update

Command (with repository-local cache environment):
`go test -C CoderNet -race -shuffle=on -count=1 -run TestNativeDERPMapUpdatePreservesSSHStream -v`

The test forwards the real native coordinator through WebSocket/yamux/DRPC.
Its DERP stream first forwards the native map, then adds region 12345 after
an SSH channel is already executing. The production SDK connection manager's
DERPMap getter confirms that the added region was applied, not merely sent.
The same SSH channel then preserves 32 ordered messages through the production
Unix-socket SSH proxy.

Results:

- `phase2-g12-b-derpmap-native.log`: native map-update test passed under race
  detection and shuffle.
- `phase2-g12-b-derpmap-go-regression.log`: full CoderNet Go suite passed with
  `-race -shuffle=on -count=1`.
- Both new Go test files returned no LSP diagnostics; gofmt reports no changes.
  gofumpt and golangci-lint are unavailable; neither was installed.
- `phase2-g12-b-derpmap-xcframework.log`: device/simulator XCFramework rebuilt.

The injection adds a region without nodes, preserving the existing usable
relay region. It proves dynamic map application and stream integrity, not
traffic migration to a new relay server. No production Go code changed.
A34 and final full-device regressions remain outstanding.
