# AGPL-3.0 License Notice — CoderNet module

This directory (`CoderNet/`) contains the BicTerm CoderNet bridge, a small
`c-archive` Go module that links code derived from and dependent on:

- **coder/coder v2**, v2.36.4 (`codersdk`, `codersdk/workspacesdk` packages)
  — licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.
  Upstream: https://github.com/coder/coder · License text:
  https://github.com/coder/coder/blob/main/LICENSE
- Coder's fork graph pinned via `replace` directives in `go.mod`
  (`coder/tailscale`, `coder/wireguard-go`, `coder/gvisor`, and the other
  `coder/*` / `kylecarbs/*` forks), which carry their upstream permissive
  licenses (BSD-3-Clause / ISC / Apache-2.0). They are listed here because
  they ship fused into the same AGPL-governed binary artifact.

Because the compiled output statically incorporates AGPL-3.0-licensed code,
the resulting artifact — `CoderNet.xcframework` and any app binary that
links it — is subject to AGPL-3.0 terms (source availability, license
propagation, network-use clause).

## Distribution impact for BicTerm

- The **default build configurations** (`Debug`, `Release`, scheme
  `BicTerm`) link this core and are therefore AGPL-3.0 binaries, suitable
  for open-source distribution.
- The **AppStore configurations** (`AppStore-Debug`, `AppStore-Release`,
  scheme `BicTerm-AppStore`) exclude the `CoderTunnel` Swift framework that
  wraps this core entirely: no object file, symbol, string, or framework
  from this module reaches those binaries (enforced by the three-layer
  audit; see `Docs/SECURITY.md`). Coder connections there use the
  Apache-2.0-clean direct-SSH path.
- The tunnel is **never downloaded at runtime** — it is either linked at
  build time or absent.

Full license texts live with the upstream projects listed above. BicTerm
source offered under this module's terms is available in the repository
itself.
