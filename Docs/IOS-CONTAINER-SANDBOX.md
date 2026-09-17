# iOS container sandbox — what the device enforces

Reference for where BicTerm (and the in-process herdr Rust client) may
create files, directories, and unix sockets at runtime. Written after the
device-only `bindFailed … NSCocoaErrorDomain Code=513 / NSPOSIXErrorDomain
Code=1` herdr bring-up failure, in which a directory creation at the data
container ROOT was denied on device while succeeding on the simulator.

**The governing fact: the simulator does not enforce container sandbox
rules. Every rule below is device-only enforcement — simulator-green tests
prove nothing about it, which is why this class of bug reached production.**

Sources are cited per section. Items Apple does not document are marked
UNVERIFIED and stated as observed behavior with corroborating reports.

## 1. The data container: where writes are allowed

The data container (`NSHomeDirectory()`, `/var/mobile/Containers/Data/
Application/<UUID>/`) is subdivided at install time into `Documents/`,
`Library/` (`Application Support`, `Caches`, `Preferences`), and `tmp/`.
Apple's current documentation says an app "can create additional
directories **inside any of these directories**" — no Apple document
sanctions creating entries at the container root itself.

- File System Programming Guide, Table 1-1:
  https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
- Files and directories technology overview:
  https://developer.apple.com/documentation/technologyoverviews/files-and-directories

### The container root is read-only on device (UNVERIFIED mechanism, well corroborated)

Creating a file or directory directly at the data-container root fails on
device with `EPERM` (`NSPOSIXErrorDomain Code=1`, wrapped by Cocoa as
`NSCocoaErrorDomain Code=513`) and succeeds on the simulator. Independent
production reproductions across iOS 15→18:

- Flutter (iOS 15): https://stackoverflow.com/questions/69834835/
- Tauri/Rust `create_dir_all` (iOS 18-era): https://github.com/tauri-apps/tauri/issues/12571
- Möbius Sync `mkdir` (iOS 16/17-era): https://github.com/MobiusSync/MobiusSync/issues/106
- BicTerm's own incident: `bindFailed(path: "/var/mobile/Containers/Data/
  Application/<UUID>/herdr-embed-transport", … Code=513 … Code=1)`.

Apple DTS's diagnostic heuristic (Quinn, DevForums): `EPERM` indicates a
sandbox/MAC denial; POSIX permission problems surface as `EACCES`. Do not
attempt to `chmod` around an EPERM — it is not a mode problem.
https://developer.apple.com/forums/thread/671979

**Rule for this project: never create anything at the container root.
Only ever write inside `Documents/`, `Library/…`, or `tmp/`, resolved via
`FileManager` URLs or `NSTemporaryDirectory()` — never via `$HOME` +
hand-built suffixes.**

### Writability summary

| Path in container | Create files/dirs on device | Backed up | System-purgeable |
|---|---|---|---|
| `.` (root) | **NO — EPERM** | — | — |
| `Documents/` | yes | yes | no (user content only — see §5) |
| `Library/` subdirs | yes | yes (except `Caches`) | no |
| `Library/Application Support/` | yes (use a bundle-ID subdir) | yes by default | no |
| `Library/Caches/` | yes | no | yes (low disk, app not running) |
| `tmp/` | yes | no | yes (app not running; timing unspecified) |
| bundle (`<App>.app`) | no (invalidates signature) | no | no |

tmp/ purge semantics: "the system may purge this directory when your app
is not running" (Table 1-1); the sweep timing is deliberately unspecified
(https://developer.apple.com/forums/thread/680224). Corollary: anything
under `tmp/` — including a bound unix socket — can vanish between runs;
always unlink-then-bind and tolerate ENOENT on connect.

## 2. FileManager vs raw POSIX: no privilege difference

FileManager is a thin wrapper over the same BSD layer; sandbox denials
propagate as the same errno (`513` wraps `1`). The Flutter (Dart), Tauri
(Rust), and BicTerm (Swift) incidents above are the same syscall failing
identically. The real hazard for a mixed Swift/Rust process is **path
resolution, not permissions**: Foundation returns container-redirected
paths, while POSIX-anchored lookups (`$HOME`, `getpwuid`, cwd-relative)
bypass or reinterpret that redirect. Any Rust code deriving storage paths
from `$HOME` or the process cwd instead of explicit paths handed over the
FFI is a sandbox-bug class of its own (see §6).

Related modern enforcement: iOS 17+ **required-reason file-timestamp
APIs** — `stat(2)`, modification-date attributes, etc. inside the
container require declared reason `C617.1` in `PrivacyInfo.xcprivacy`, or
App Store Connect warns (ITMS-91053).
https://developer.apple.com/documentation/bundleresources/privacy_manifest_files

## 3. chdir(2) and process env on iOS (UNVERIFIED from Apple docs)

No Apple document blesses or forbids `chdir` in an iOS app. Established:

- `chdir` is process-local; it cannot widen sandbox access. Relative
  paths are still sandbox-checked per access.
- The launch-time cwd on device is not a documented contract — **never
  rely on the initial cwd**.
- Apple's path guidance explicitly prefers well-known directories over
  cwd-relative resolution (technology overview, §1).

BicTerm pins the process cwd to the container home during an embedded
herdr run so that the bridge server and the Rust client resolve the SAME
relative socket path (`tmp/herdr-embed-transport/<profile>.sock`) against
it — Darwin's 104-byte `sun_path` (§4) makes the ~60-char container
prefix plus a deep subpath unusable as an absolute socket path. The pin
is owned (`HerdrEmbedTransportWorkspace`) and restored at teardown. This
is legal; it buys path shortness, not sandbox relief.

## 4. Unix domain sockets on iOS

- `sun_path` is **104 bytes including NUL** on Darwin (Apple's published
  XNU source, `bsd/sys/un.h`):
  https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h
  The container prefix alone consumes ~60 bytes; an app-group prefix ~63.
  Keep socket paths short and shallow — this is why the herdr bridge
  binds a relative path under a pinned cwd.
- `bind(2)` inside the app's own container is permitted, no entitlement
  (Apple DTS: "You shouldn't need to do anything special to use UNIX
  domain sockets in a sandboxed app":
  https://developer.apple.com/forums/thread/126059).
- Cross-PROCESS sockets (app ↔ extension) must live in a **shared app
  group container**; an extension cannot reach the host app's data
  container. Working iOS pattern:
  https://ddeville.me/posts/2015/02/11/interprocess-communication-ios-berkeley-sockets
- Same-process pairs can avoid the filesystem entirely with
  `socketpair(2)` (no path limit, no stale-file or purge problem).
- A socket under `tmp/` inherits tmp's purge semantics (§1): treat the
  path as ephemeral; unlink before bind, sweep-or-refuse on stale vs
  live ownership (the `HerdrEmbedBridgeServer` contract).

## 5. Directory roles, backup, and App Review

- `Documents/` is for **user-visible** content only; app-managed state
  belongs under `Library/` (Application Support) — the historical App
  Review guideline 2.23 enforced the iOS Data Storage Guidelines; the
  substance survives in the guidelines preamble and the current canonical
  doc "Optimizing Your App's Data for iCloud Backup":
  https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup
  (exact current rule numbering: UNVERIFIED).
- Re-creatable data under `Library` should carry
  `NSURLIsExcludedFromBackupKey`; purgeable data belongs in `tmp/` or
  `Library/Caches/`.

## 6. The embedded herdr client's anchor contract (audit result)

The vendored Rust client resolves its directories as
`$XDG_CONFIG_HOME/herdr`, `$XDG_STATE_HOME/herdr`, with fallbacks to
**`$HOME/.config/herdr` and `$HOME/.local/state/herdr`**
(`Vendor/herdr/upstream/src/config/io.rs`). `$HOME` is the container
root, so a missing XDG anchor means a mkdir at the container root → the
§1 EPERM class on device, silent log/state loss on simulator.

Therefore the embed contract is: **both XDG anchors (plus
`HERDR_CONFIG_PATH` and `HERDR_EMBED_STDERR_LOG`) are set before the
client boots, in every mode** — `HerdrEmbedTransportCoordinator.prepare()`
(`applyEnvironment`) for transport runs, and
`HerdrEmbedRuntime.prepareClientEnvironment()` unconditionally. Both
point at `Library/Application Support/herdr-embed/{config-home,state-home}`
— compliant, backed-up, non-purgeable locations. The bridge sockets are
the exception: `tmp/herdr-embed-transport/` is deliberately purgeable
(ephemeral by design, §1/§4).

Regression coverage: `BicTermTests/Herdr/HerdrEmbedTransportBringUpTests`
asserts the transport path shape against the SPEC (hardcoded
`tmp/herdr-embed-transport`, not the production constant) and includes a
no-seam variant that runs against the real app home — on device this
exercises the exact sandboxed path from the incident.

## 7. Other device-only behaviors worth knowing

- **Data protection classes**: third-party files default to class C
  (`CompleteUntilFirstUserAuthentication`); class-A files return `EPERM`
  while the device is locked — the same errno as a sandbox denial.
  Background/locked access needs `completeUnlessOpen` on the file AND its
  parent directory. https://support.apple.com/guide/security/data-protection-classes-secb010e978a
- **Container UUID instability**: the container path changes across
  device migration/restore; never persist absolute container paths —
  persist relative ones and re-anchor at launch
  (corroborating incident: https://github.com/deltachat/deltachat-ios/issues/1762).
- **iOS 17**: bundle and data container now live on different volumes;
  never assume cross-volume renames or bundle-anchored temp dirs
  (https://developer.apple.com/forums/thread/735726).
- **Preflight writability checks are unreliable** inside the container
  (POSIX/ACL/MAC/sandbox layering disagrees with `isWritableFile`);
  attempt the operation and handle the error
  (https://forums.swift.org/t/swift-filemanager-on-ios-device-wrong-different-resourcevalues-for-execute-read-write/44671).

## 8. Audit scorecard (2026-09, post-incident)

| Touchpoint | Location | Verdict |
|---|---|---|
| Bridge sockets bind/chmod/unlink | `<home>/tmp/herdr-embed-transport/` (relative, pinned cwd) | compliant; ephemeral by design |
| Client catalog seed/rewrite | AppSupport `herdr-embed/state-home/herdr/client/` | compliant |
| Client config + stderr log | AppSupport `herdr-embed/` | compliant |
| Client logs, session data, shell prefs | AppSupport `herdr-embed/config-home/herdr/`, `state-home/herdr/` | compliant **given XDG anchors set pre-boot** (fixed: legacy mode now sets `XDG_STATE_HOME` too) |
| SwiftData stores | AppSupport `BicTerm/*.store` | compliant |
| Keychain / Secure Enclave | SecItem, data-protection keychain | compliant (not filesystem) |
| User-picked file reads (clipboard image, key import) | security-scoped URLs | compliant (read-only) |
| SwiftTerm kitty graphics | reads only under `/tmp`, `/dev/shm`, `temporaryDirectory` | compliant |
| UserDefaults settings | container `Library/Preferences` | system-managed, compliant |

Known UNVERIFIED items (treat as observed, not guaranteed): the exact
sandbox-profile rule and first iOS version denying container-root writes
(reports cluster at iOS 15+); whether `tmp/` contents can be relaxed to
data-protection class None; Apple's stance on `chdir` in iOS apps; the
current App Review rule number for data storage.
