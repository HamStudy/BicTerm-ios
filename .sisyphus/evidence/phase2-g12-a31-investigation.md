# A31 investigation

The verified EOF checkpoint is f5f619a; harness checkpoint is 71f6e30.
Debugging Go runtime and root-cause/TDD methodology references were read.

Hypotheses:
1. Proxy write errors do not close upstream, leaving other relays blocked.
   A failing I/O-boundary Go test now reproduces this; closing upstreamConn
   on copy error makes it green. The unchanged native harness still times out.
2. OpenSSH's local stdout-reader closure does not propagate a channel write
   failure to the proxy. Capture verbose SSH control events for the A31 case.
3. Upstream close does not unblock its reads. The Go test's completion signal
   after the write-error fix refutes this for the injected failure case.

Temporary instrumentation planned: DEBUG3 only for the harness's A31 SSH
child, copied to phase2-g12-a31-openssh.log; remove after diagnosis.
No UI changes or root debug journal. Child process groups are bounded and
terminated by the existing harness cleanup on timeout.

## Confirmed cause and fix

Local sources inspected:
- `.build-artifacts/go-mod/golang.org/x/crypto@v0.54.0/ssh/channel.go:467-475`
  forwards channel requests unchanged to incomingRequests; EOW is not filtered.
- `ssh/server.go:252-257` defines the customizable RFC 4253 identification.
- `ssh/transport.go:305` supplies the default `SSH-2.0-Go` identification.

No repository-local OpenSSH PROTOCOL document was found. The client-side
compatibility behavior was validated empirically against `/usr/bin/ssh`
OpenSSH_10.3p1, rather than attributed to an unread source file.

The default-Go trace (`phase2-g12-a31-openssh-before.log`) records local
`write failed`, `send eow`, then continuing window adjustments, without a
channel-request packet after EOW. Changing only the server identification to
`SSH-2.0-OpenSSH_compat_BicTerm` causes the positive trace
(`phase2-g12-a31-openssh.log`) to report:

```
compat_banner: match: OpenSSH_compat_BicTerm pat OpenSSH* compat 0x04000000
channel 0: send eow
send packet: type 98
channel 0: rcvd close
Exit status -1
```

The identifier explicitly names compatibility/BicTerm, not an OpenSSH release.
The proxy handles the received end-of-write request by closing its owned
upstream connection, which unblocks both data directions and request relays.
Direct output-copy errors use the same upstream close path. Ordinary stdin
EOF still half-closes and drains, preserving the previous regression fix.

Toggle proof: reverting identification to `SSH-2.0-Go` reproduced the
unchanged harness timeout (`phase2-g12-a31-toggle-red.log`); restoring the
compatibility identifier made it pass (`...-native-green.log`). The temporary
DEBUG3 setting and tee were removed. The committed harness uses LogLevel=ERROR.

## Executed verification

```
source scripts/env-local-caches.sh
go -C CoderNet test -race -count=1 -run TestSSHProxyReturnsWhenDownstreamWriteFails -timeout=30s
go -C CoderNet test -race -count=1 -run TestSSHProxyReturnsWhenConsumerSendsEndOfWrite -timeout=30s
CODER_LIVE_PROBE=1 go -C CoderNet test -race -shuffle=on -count=1 -v -timeout=120s ./...
bash scripts/test-coder-raw.sh
CODER_GATE_RELAY_ONLY=1 bash scripts/test-coder-raw.sh
bash scripts/build-coder-net.sh
```

Red logs: `phase2-g12-a31-write-red.log`, `...-eow-red.log`, `...-toggle-red.log`.
Green logs: `...-write-green.log`, `...-eow-green.log`, `...-go-final.log`,
`...-native-green.log`, `...-relay-green.log`, `...-xcframework.log`.
The post-rebuild live Swift suite is `phase2-g12-a31-live-swift.log`, executed
with `ONLY_TESTING=BicTermCoreTests/CoderTransportConformanceTests`, canonical
iPhone destination, and repository-local DerivedData. A31 is PASS; this is
not a claim that the remaining protocol matrix is complete.
