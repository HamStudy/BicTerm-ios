# Device QA handoff — physical iPad smoke pass

Task T20. Agents cannot run on a physical iPad; this is the explicit
user-QA-handoff entry referenced by `Docs/HERDR-RELEASE-TRACEABILITY.md`.
Estimated time: 30–45 minutes on one iPad (plus optional second host for
multi-machine rows).

## Setup

- A physical iPad on a supported iPadOS version, BicTerm installed via
  Xcode (Debug or TestFlight/AppStore-Release build — note which).
- One reachable SSH host with a compatible Herdr endpoint (the same
  fixture sshd on 12222/12223 works if the iPad can reach the Mac:
  connect to `<mac-LAN-IP>` port 12222 with the fixture user/key).
- Console.app on the Mac, filtering process `BicTerm`, subsystem
  `com.bicterm.app.herdr` — expected log lines are phase transitions only
  (`online:…`, `closed:…`); **no pane content, clipboard text, or
  credentials may ever appear** (a sighting is a release blocker).

## Smoke checklist

Each step lists the expected signal. Record pass/fail + a screenshot or
Console excerpt per step.

| # | Step | Expected signal |
|---|---|---|
| 1 | Add the host as a connection; connect | Terminal workspace renders the remote panes; status badge reaches Online |
| 2 | First-connect host-key prompt (new host) | TOFU fingerprint sheet appears; accepting stores trust; rejecting aborts cleanly |
| 3 | Keyboard input | Typed text appears in the focused pane echo; focus retarget by pane tap moves input |
| 4 | Hardware keyboard chords (Ctrl/arrow/Home/End) | Semantic keys route (echo line shows key names, not garbled bytes) |
| 5 | Software keyboard + IME (CJK or accented) | Committed text only reaches the remote; no duplicate delivery |
| 6 | Copy from remote (banner) after remote clipboard arrives | Banner shows byte count; Copy writes the pasteboard only on tap |
| 7 | Paste (text) into a pane | Content appears remotely; no bracketed-paste double-wrap artifacts |
| 8 | Image paste (small PNG) | Sheet offers metadata toggle + downscale; paste sends; remote shows image placeholder behavior per host |
| 9 | Background the app ~10 s, foreground | Detach on background, reconnect prompt or automatic re-attach on foreground; workspace state preserved (T19 policy) |
| 10 | Kill the remote herdr/server process | `Herdr server stopped` diagnostic (not a silent hang); Reconnect offered |
| 11 | Network loss (Wi-Fi off) | `Connection lost` diagnostic within seconds; bounded reconnect with visible attempt counter; Cancel works |
| 12 | Resize: rotate + Split View width change | Remote grid follows geometry in order; no input loss during resize |
| 13 | Forget Host (swipe a connection → Forget Host) | Host-key prompt re-appears on next connect; stored state cleared for that host only |

## Optional deeper matrices (traceability rows marked User QA)

- iPadOS version matrix: repeat steps 1–9 on the oldest supported iPadOS.
- Network matrix: IPv6-only network, LAN permission deny then allow,
  Wi-Fi↔cellular handoff, VPN active, captive portal — expect typed
  diagnostics, never hangs (steps 9/11 signals).
- Multitasking: Split View, Stage Manager, external display, rotation
  during steps 9/12; memory-pressure warning during a large paste.
- Accessibility: VoiceOver traverse of the workspace chrome, Dynamic Type
  largest size, hardware keyboard only navigation.

## Evidence capture

- Console.app: filter subsystem `com.bicterm.app.herdr`, save a session
  transcript per smoke run (`.logarchive` via File → Save; or
  `sudo log collect` — attach to the release evidence as
  `.sisyphus/evidence/device-qa-<date>.{log,logarchive}`).
- Screenshots: iPad Side Button + Volume Up; AirDrop or Photos import.
- sysdiagnose (only for a failure): hold both volume buttons + side button
  briefly, or Settings → Privacy & Security → Analytics → start; share the
  `.ips.tar.gz` alongside the matching Console transcript.

## Reporting back

Append results to `.omo/notepads/bicterm-phase2-coder-ssh/learnings.md`
(or a new `.sisyphus/evidence/device-qa-<date>.md`) with: build flavor,
iPadOS version, per-step pass/fail, and the Console excerpt for any
failure. A release must not ship with an unreviewed failure in steps 1–12.
