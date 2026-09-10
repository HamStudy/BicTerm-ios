# Draft: reusable endpoint client libraries

**Unsubmitted.** No GitHub issue or PR was opened, and no upstream approval
is implied. Discussion destination:
https://github.com/herdrdev/herdr/discussions

The pinned [CONTRIBUTING.md](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/CONTRIBUTING.md)
directs feature and architecture proposals to Discussions. It does not permit
an external agent to open a feature-request issue or an unsolicited
implementation PR. The acting account was not verified as a maintainer.
This local draft is not evidence of completed upstream engagement.

## Proposed discussion text

We are exploring an embedded native iOS client for independently installed
Herdr servers, using an existing SSH engine's non-PTY exec channels. The app
would never install or update remote Herdr and would not run the desktop
binary, local server, PTYs, or SSH subprocesses on iOS.

Our v0.9.0 fork now separates protocol data from desktop conversion helpers
and exposes transport-neutral catalog, health, retry and activation state.
The activation/presentation fence remains intact, tested separately from
desktop rendering. Both iOS targets compile, and frozen frames cover every
outer message variant. This makes a small client-library boundary concrete
without independently reproducing bincode or copying the desktop UI.

Would a supported library boundary for this use case fit Herdr's direction?
We would value guidance on generation-1 compatibility, conformance fixtures,
and preferred attribution. We are maintaining a local fork independently;
this discussion is not a request to bypass contribution approval.
