# HerdrClientCore

## OVERVIEW
Swift actor wrapper over the herdr Rust FFI (`HerdrCore.xcframework`); static-link framework, no UI.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Actor, FFI calls, lifecycle | `HerdrClient.swift` | `HerdrClient` actor: `receive`, `drainOutbound`, `snapshot`, `surfaceJSON`, `sendText`/`sendPaste`/`sendKey`/`sendClipboardImage`, `resize`, `destroy` |
| Errors, config, key input | `HerdrClientModels.swift` | `HerdrClientError` (typed mirror of `HERDR_CODE_*`), `HerdrPhase`, `HerdrClientConfig`, `HerdrKeyCode`/`HerdrKeyKind`/`HerdrKeyInput` |
| Snapshot value types | `HerdrShellSnapshot.swift` | `HerdrShellSnapshot`, `HerdrWorkspace`, `HerdrTab`, `HerdrPane`, `HerdrAnnouncement`, all decoded from `shell.snapshot.v1` JSON |
| C ABI declarations | `HerdrCoreC/include/HerdrCore.h` | cbindgen-generated; consumed via `import HerdrCore` |
| C module host object | `HerdrCoreC/stub.c` | empty TU; the real archive is the xcframework |
| Machine code | `.build-artifacts/herdr/HerdrCore.xcframework` | arm64 device+sim, headerless; built by `scripts/build-herdr-core.sh` from `Vendor/herdr/herdr-ios-ffi` |
| Tests | `HerdrClientCoreTests/` (one scheme `HerdrClientCore`) | replay golden frames from `Vendor/herdr/herdr-protocol/tests/fixtures/golden` |

## CONVENTIONS (only where this dir differs from root)
- `HerdrCoreC` is a static-link framework (`MACH_O_TYPE: staticlib`) emitting only the clang module + stub; machine code resolves from the xcframework at app link time.
- `HerdrClientCore` is also `staticlib`, `embed: false`. The app target links it without embedding; `-u _herdr_client_create` in `BicTerm.OTHER_LDFLAGS` keeps the headerless xcframework objects in the app binary.
- Swift side never touches the wire protocol: bytes in/out are opaque `Data`. Frame parsing, encoding, and the frozen bincode codec live in Rust.

## ANTI-PATTERNS
- Reimplement frame parsing in Swift. The codec stays in Rust; Swift only marshals typed values.
- Hand-edit `HerdrCoreC/include/HerdrCore.h`. It is cbindgen-generated; the build script writes it back on drift and the run fails loudly.
- Embed `HerdrClient` or `HerdrCoreC` into the app bundle (`embed: false` only; embedded stub frameworks fail bundle validation).
- Build with a generic simulator destination. The xcframework is arm64-only; x86_64 simulator slice does not exist. Always name a simulator (e.g. `iPhone 17 Pro`).
- Skip the `BicTerm` linker anchor `-u _herdr_client_create` when restructuring `BicTerm.OTHER_LDFLAGS`; without it the linker drops every object in the static archive.
- Touch `Vendor/herdr/herdr-ios-ffi/src/abi.rs` from this dir; patch it upstream and document the hunk in `Vendor/herdr/MODIFICATIONS.md`.
- Run herdr integration against a live `herdr-server` on this host. zig 0.15.x fails to link on macOS 26; tests stay on committed-frame replay.

## NOTES
- `build-herdr-core.sh` installs cbindgen repo-locally into `.build-artifacts/tools/` on first run and refuses to ship a headerless archive without `_herdr_client_create` in `nm -gU`.
- `HerdrClientConfig.maxFrameSize` and `outboundByteLimit` exist so tests can lift the protocol default; the app sets `outboundByteLimit` large enough to hold a 16 MiB clipboard image frame.
- `clipboardDropped` is non-fatal by design; the client stays Online and keeps decoding subsequent frames.
- Tests have their own scheme `HerdrClientCore` (separate from `BicTerm`); run via `xcodebuild ... -scheme HerdrClientCore test` or the test scripts.
