# v0.9.0 framed conformance vectors

Captured by `cargo run -p herdr-protocol --example capture_golden_frames`
from the extracted, unmodified v0.9.0 bincode serialization/framing path.
The source pin is `b99002ac99b09e00b4ca692436cb15a6b0d676f1`. These are
binary `[u32 little-endian length][bincode standard payload]` frames, not
hand-authored bytes and not captures from a running remote server.

- `client-00.bin` through `client-20.bin`: all 21 frozen client enum variants,
  in wire-tag order. Tag 20 contains a real generation-1 endpoint hello.
- `server-00.bin` through `server-20.bin`: all 21 frozen server enum variants,
  in wire-tag order. Tag 20 contains a v0.9.0 endpoint welcome.
- `server-21.bin`: the stable JSON snapshot carrier (outer wire tag 20).

The exact typed inputs are in `tests/support/{client,server}_samples.rs`.
Pane and popup input vectors include semantic key/physical/Windows identity,
text commit, pixel mouse geometry, and multiline paste. Samples also cover
binary stdout/graphics/image bytes, hyperlinks, style bits and non-ASCII text.
Unchanged upstream digest/tag tests independently constrain the extracted
type layout; these vectors do not replace those assertions.

Normal tests never rewrite fixtures. They encode each typed sample, compare
the complete frame bytes, check its upstream tag, decode the committed frame,
and compare the complete typed value. A generation-1 mismatch must be
investigated, not accepted by rerunning the capture tool.

The protocol preserves legacy/desktop message variants for frozen wire
layout. Their presence is not permission for the iOS core to execute a file
path, update command, direct graphics command, or desktop configuration reload.
