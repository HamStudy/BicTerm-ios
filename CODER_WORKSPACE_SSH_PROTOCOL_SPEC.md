# Coder workspace SSH client: protocol and implementation specification

> **HISTORICAL SPEC. DO NOT IMPLEMENT.** Coder/AGPL tailnet support was
> removed from this project in commit `ee9956e` ("refactor!: remove Coder
> support and all AGPL-linked code"). This document is retained as a
> historical research record only; do not implement from it and do not
> resurrect Coder patterns.

**Research date:** September 6, 2026  
**Reference release:** Coder `v2.36.4`  
**Reference commit:** `10fd510ada0e3a7c222511dbd9916f83afd1acf0`  
**Intended consumer:** A coding agent implementing an authorized client for an existing Coder deployment.

## 0. Read this first

Coder workspace SSH is **not simply SSH inside a WebSocket connected to an `/ssh` endpoint**. The native connection path consists of:

1. Authenticated HTTP API calls to identify the workspace and its running agent.
2. An authenticated WebSocket carrying **Yamux → DRPC → protobuf** coordination messages.
3. A userspace, WireGuard-based network connection to the agent, using direct UDP when possible and a DERP relay otherwise.
4. A virtual TCP connection to the agent's built-in SSH service.
5. Ordinary SSH over that TCP connection. [S06–S17]

The recommended implementation is a **Go transport core using Coder's `codersdk/workspacesdk` package**, with a raw-stdio adapter that an existing SSH client can use as a ProxyCommand. This creates a real client without shelling out to the Coder executable, while retaining Coder's implementation of coordination, NAT traversal, encryption, relay fallback, and reconnection.

The key SDK operation is:

```go
agent, err := workspacesdk.New(apiClient).DialAgent(dialCtx, agentID, options)
// Check err, then:
rawSSH, err := agent.SSH(dialCtx)
```

`rawSSH` is a bidirectional SSH byte stream, not a terminal session. The caller must close both the SSH stream and the owning `AgentConn`. The current SDK returns an `AgentConn` **interface**, not a pointer to an `AgentConn` struct. [S06, S08]

This document describes the Coder-specific protocol and the implementation contracts needed to use it. The upstream implementations of WireGuard, Tailscale discovery, DERP, Yamux, DRPC, protobuf, and SSH remain normative for their respective standard/dependency-level details. It is not a substitute cryptographic specification for reimplementing all those components from scratch.

### Evidence and validation boundary

The findings come from reading the released client, server, agent, protobuf, and dependency implementations. The reference tag was resolved to the full commit above. The Tailscale fork examined is the exact revision named by that release's `go.mod`: `b7c5fc6e6399`. [S01, S19]

**No client was compiled or connected to a live Coder deployment during this research.** The code sketch below is source-derived, not a tested deliverable. The implementation must run the acceptance tests in section 18 against the actual target deployment before being called compatible.

“MUST,” “SHOULD,” and “MAY” below specify the proposed client's requirements. Statements about upstream behavior are distinguished from proposed design choices. Configurable timeout values are design defaults, not Coder protocol constants.

## 1. Scope and architecture

### 1.1 Required result

The first implementation MUST let a user with legitimate Coder access establish an ordinary SSH session to a selected workspace agent. It MUST support a raw stream mode so OpenSSH or another SSH library can provide interactive shells, commands, SSH subsystems, and forwarding, subject to server policy.

The minimum product comprises:

- A profile containing the deployment URL, a reference to a securely stored user token, and optional connection preferences.
- Workspace and agent discovery, with explicit selection when ambiguous.
- A connection manager using the Coder SDK.
- A raw-stdio adapter, with all diagnostics confined to stderr.
- Separate authentication setup and structured error handling.

Starting a stopped workspace is optional functionality that MUST be explicitly enabled. Creating workspaces, editing templates, operating provisioners, obtaining workspace-agent credentials, and exposing a public SSH gateway are not prerequisites.

### 1.2 Components and traffic

```text
                         CONTROL PLANE
  Client ------------------------------------------------> Coder server
     |        HTTPS REST: identity, workspace, agent, configuration
     |        WSS /workspaceagents/{agent}/coordinate?version=2.0
     |           binary byte stream
     |             Yamux multiplexing
     |               DRPC calls with protobuf messages
     |                   |
     |                   +---- authorized peer/key/endpoint exchange
     |
     |                    DATA PLANE
     +---------- WireGuard packets over direct UDP ----------> Agent
     |                                                           |
     +---- DERP relay connection ---- encrypted packets ----------+
                                                                 |
                                               userspace virtual IPv6/TCP
                                                                 |
                                                 agent virtual TCP port 1
                                                                 |
                                                   built-in SSH server
                                                                 |
                                                 shell / exec / SFTP / forwarding
```

The coordinator WebSocket and the DERP relay connection are distinct connections with distinct payload protocols. A relay connection can itself use WebSocket transport, but neither connection is a public raw-SSH WebSocket endpoint. [S06–S14, S23–S25]

### 1.3 Platform strategy

A desktop command-line client can expose stdin/stdout to OpenSSH. A graphical or mobile application can use the same Go core through an appropriate binding and connect its SSH library to the resulting stream. Platform-specific builds and bindings need separate validation; this research does not establish that the complete Go dependency graph will build unchanged for every mobile target.

A gateway can reuse the same transport core on behalf of an authenticated remote user. However, accepting an incoming public TCP stream and blindly relaying it to `agent.SSH()` is unsafe: the upstream agent does not demand a second SSH password or key. A gateway needs its own authenticated user-to-token-to-workspace authorization boundary. Section 17 explains this distinction. [S17]

## 2. Identities and credentials: keep them separate

| Item | Representation | Purpose |
|---|---|---|
| Deployment URL | HTTPS origin | Identifies the trusted Coder installation. |
| Coder user/session/API token | Opaque secret string | Authenticates REST calls and coordination setup. |
| User ID | UUID | Identifies the authenticated Coder account. |
| Workspace ID | UUID | Stable identity of the workspace resource. |
| Workspace build ID | UUID | Identifies a particular provisioner build. |
| Workspace agent ID | UUID | Selects the agent whose SSH service will be reached. |
| Coordinator peer ID | UUID, assigned/recovered by server | Identifies a particular coordination participant. |
| Tailnet Node ID | Integer, not a UUID | Network-engine node identifier; not interchangeable with agent ID. |
| WireGuard node key pair | Curve25519-compatible key material | Authenticates/encrypts the peer network connection; also used in DERP client authentication. |
| Discovery/disco key pair | Separate key material | Authenticates peer-path discovery. |
| Resume token | Opaque server-issued token | Recovers the coordinator peer identity after reconnecting. |
| SSH host key | SSH public/private key pair | SSH protocol server key; the stock SDK relies on tunnel identity instead of checking this independently. |

These distinctions follow the SDK, coordinator, and key implementations. [S02–S10, S14–S15, S21–S22]

**A resume token is not a replacement for a Coder login token.** The coordinate endpoint still authenticates and authorizes the request before processing it. An invalid resume token must not automatically trigger a login prompt. [S07, S09]

**A workspace-agent token is not a user credential.** A client does not need to impersonate the agent or obtain its provisioning credential. Likewise, the user's Git SSH key API is not part of this connection sequence.

Names are presentation/selection data. Cache a deployment-scoped workspace UUID and an agent selector, but re-resolve the agent against the latest build after rebuilds. Do not assume the agent UUID or its network public key remains unchanged across lifecycle transitions.

## 3. Deployment prerequisites and policy

The deployment already needs a provisioned workspace with a Coder agent that can connect to its Coder server. Both client and agent need access to the control plane and to a usable relay path. Direct connectivity additionally depends on UDP reachability and NAT traversal; it is an optimization, not a reason to expose the workspace's host SSH port publicly. The SDK uses a userspace network stack and does not require an OS TUN interface for the ordinary single-agent connection. [S06, S14, D02]

The implementation MUST honor:

- Server-side SSH authorization.
- Server-enforced direct-connection restrictions.
- Browser-only restrictions that disable native coordination.
- Agent-side restrictions on file transfer and local/reverse port forwarding.
- Workspace lifecycle and template policy.

The coordinate handler checks `policy.ActionSSH` and deliberately returns a resource-not-found response when this authorization check fails. Therefore, successfully listing a workspace does not prove SSH access, and an HTTP 404 from coordination can represent a permission denial. [S09]

The client MUST NOT request administrator-only deployment configuration merely to connect. Connection information is available through the agent connection endpoint. [S06, S09, S20]

## 4. Authentication setup

### 4.1 Recommended initial authentication

Accept a user-supplied Coder session/API token and validate it before saving the profile. For browser-backed sign-in, open the deployment's `/cli-auth` page in the system browser and let the user complete the deployment's normal authentication process. The resulting token can be entered into the client's dedicated login UI or command. This preserves the deployment's existing sign-in mechanisms instead of implementing an assumed password-only flow. [D01]

Use the following header for authenticated requests:

```http
Coder-Session-Token: <opaque-user-token>
```

Coder defines this header explicitly; the stock SDK's token-provider abstraction supplies authentication to requests and WebSocket dial options. [S02, S06–S07]

Validation request:

```http
GET /api/v2/users/me HTTP/1.1
Host: coder.example.test
Coder-Session-Token: <token>
Accept: application/json
```

Expect a successful user response and record its user ID. Use `client.User(ctx, codersdk.Me)` with the SDK. An identity lookup alone is not proof of permission to reach a specific workspace. [D03]

The client's login flow MUST keep credentials out of command history, ordinary configuration exports, logs, errors, and raw SSH stdin/stdout. Prefer an OS credential store. A permissions-restricted token file is an explicit fallback, not a universally secure equivalent.

### 4.2 Optional API token creation

A client that already has a valid user credential can explicitly create a separate named API token. This is optional; it is not an unauthenticated bootstrap mechanism.

```http
POST /api/v2/users/me/keys/tokens
Content-Type: application/json
Coder-Session-Token: <existing-valid-token>

{
  "lifetime": 86400000000000,
  "token_name": "coder-ssh-client"
}
```

Here `lifetime` is a JSON integer encoding Go `time.Duration`: **nanoseconds**, so this illustrative request is one day. It is not seconds and not an ISO duration string. The response contains `{"key":"..."}`. The request also supports `scopes` and `allow_list`. Creation must comply with the deployment's lifetime and permission restrictions. Omitting scopes uses the server's default permission behavior; it is not a claim that unrestricted tokens are necessary. [S03]

Relevant optional management calls:

| Method and path | Purpose |
|---|---|
| `GET /api/v2/users/me/keys/tokens/tokenconfig` | Read token lifetime configuration. |
| `GET /api/v2/users/me/keys/tokens` | List token metadata; not a way to retrieve all existing secret values. |
| `GET /api/v2/users/me/keys/{keyID}` | Inspect known key metadata, including expiry. |
| `PUT /api/v2/users/me/keys/{keyID}/expire` | Expire a token while retaining its record. |
| `DELETE /api/v2/users/me/keys/{keyID}` | Delete the specified key. |

The SDK also exposes `POST /api/v2/users/me/keys` for browser-like session creation, but its own documentation prefers named token creation for trackable long-lived access. A client MUST NOT silently create or revoke tokens without the user's requested authentication action. [S03]

### 4.3 Expiry and scopes

Coder documents configurable session durations and automatic session-expiry refresh, while API token lifetimes are separately controlled. Do not invent a generic OAuth refresh-token endpoint for an opaque Coder token. Once authentication is genuinely invalid, reacquire a credential using the supported sign-in flow. [D01]

The coordinate handler requires SSH authorization, not just metadata read access. Exact minimal scopes depend on all enabled client functions: identity lookup, discovery, starting builds, token inspection, usage reporting, and SSH. Test scoped credentials against those actual calls. Do not claim that `workspace:read` or an application-only scope is sufficient without verification. [S09]

Store a credential generation number with every connection. A replacement token MUST be validated with a fresh API client, including checking the expected account identity. Then atomically replace the stored token and create a fresh transport for subsequent connections. Do not mutate a shared SDK client's token provider concurrently or assume already-created WebSocket dial options will pick up every mutation.

## 5. HTTP API inventory and initial connection sequence

All paths below are relative to the trusted deployment. Encode path segments and query parameters using a URL library, not string concatenation of unvalidated user input. Synthetic examples use the reserved example domain `coder.example.test`.

| Order | Method and endpoint | Expected result | Role |
|---|---|---|---|
| Optional | `GET /api/v2/buildinfo` | `200`, build/version information | Record server version for compatibility diagnostics. |
| 1 | `GET /api/v2/users/me` | `200`, user | Validate a supplied credential/identity. |
| 2a | `GET /api/v2/workspaces?q=owner%3Ame&limit=100&offset=0` | `200`, `{workspaces,count}` | Discover owned workspaces; paginate as needed. |
| 2b | `GET /api/v2/users/{owner}/workspace/{name}` | `200`, workspace | Resolve a known owner/name; `me` is supported. |
| 2c | `GET /api/v2/workspaces/{workspaceID}` | `200`, workspace | Resolve or refresh a known UUID. |
| Optional | `GET /api/v2/workspaces/{workspaceID}/resolve-autostart` | `200`, `{parameter_mismatch}` | Check whether autostart encounters parameter mismatch. |
| Optional | `PUT /api/v2/workspaces/{workspaceID}/dormant` | `200` or `304` | Explicitly reactivate with `{"dormant":false}`. |
| Optional | `POST /api/v2/workspaces/{workspaceID}/builds` | `201`, build | Explicitly start a stopped workspace. |
| 3 | `GET /api/v2/workspaceagents/{agentID}` | `200`, agent | Check agent connection/lifecycle state. |
| Optional | `GET /api/v2/workspaceagents/{agentID}/logs?after=0` | `200`, log records | Explain startup delays/failures. |
| 4 | `GET /api/v2/workspaceagents/{agentID}/connection` | `200`, connection info | Obtain DERP map and connection policies. |
| 5 | WebSocket `GET /api/v2/workspaceagents/{agentID}/coordinate?version=2.0` | `101`, binary stream | Establish tailnet coordination. |
| During use | `POST /api/v2/workspaces/{workspaceID}/usage` | `204` | Report actual SSH usage, when enabled. |

These paths are implemented by the workspace, agent, connection, and deployment SDK/server code. Identity API shape is also documented in the official user API. [S04–S09, S20, D03]

`GET /api/v2/workspaceagents/connection` is a generic alternative for connection information. The single-agent SDK path uses the agent-specific endpoint. The generic response does not independently authorize SSH to every agent. [S06, S09]

### 5.1 Minimal workspace response consumed by the client

A useful reduced representation is:

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "owner_id": "22222222-2222-4222-8222-222222222222",
  "owner_name": "alice",
  "name": "dev",
  "dormant_at": null,
  "latest_build": {
    "id": "33333333-3333-4333-8333-333333333333",
    "status": "running",
    "transition": "start",
    "resources": [
      {
        "agents": [
          {
            "id": "44444444-4444-4444-8444-444444444444",
            "name": "main",
            "status": "connected",
            "lifecycle_state": "ready",
            "scripts": []
          }
        ]
      }
    ]
  }
}
```

This is a synthetic subset, not a complete API schema. Preserve/ignore additional fields appropriately. Discover live agent identities from the **latest build's resources**, not a template preview or a template-version dry run. The current build API documentation marks the old separate build-resources endpoint removed; do not build a new client around an obsolete `/workspacebuilds/{id}/resources` call. [S04–S05, D04–D05]

### 5.2 Workspace resolution

The SDK exposes:

```go
client.Workspaces(ctx, codersdk.WorkspaceFilter{Owner: codersdk.Me})
client.WorkspaceByOwnerAndName(ctx, owner, name, codersdk.WorkspaceOptions{})
client.Workspace(ctx, workspaceID)
client.ResolveWorkspace(ctx, identifier)
```

`ResolveWorkspace` accepts a UUID, a bare name owned by `me`, or `owner/name`. A workspace list name filter is a partial-match filter, so it is not a substitute for exact lookup. The built-in resolver also handles certain UUID-looking names. [S04]

MVP selection policy:

- An explicit agent UUID must belong to the selected workspace's current build.
- An explicit agent name must match exactly and unambiguously.
- Without an agent selector, one eligible agent can be selected automatically.
- With multiple candidates, return a structured ambiguity error containing candidate names/IDs. Do not silently pick the first array element.

Do not equate a workspace with a single VM/container/agent. Nested agent/subagent support exists in the agent schema; selection should be based on actual returned identities, not assumptions about infrastructure layout. [S05]

## 6. Workspace lifecycle and readiness

### 6.1 Starting a stopped workspace

Starting can incur cost and run provisioning/startup code. It MUST be an explicit profile or command policy, such as `--start`, rather than an unconditional side effect.

For a stopped, non-dormant workspace, the minimal start request is:

```http
POST /api/v2/workspaces/{workspaceID}/builds
Coder-Session-Token: <token>
Content-Type: application/json

{
  "transition": "start",
  "reason": "ssh_connection"
}
```

The SDK's `CreateWorkspaceBuildRequest` supports these values. Optional template-version and rich-parameter fields exist, but the client MUST NOT automatically supply a different active template version or overwrite parameters just to make a connection attempt succeed. Respect automatic-update/required-version policies and surface parameter requirements for the user to resolve. `ResolveAutostart` can expose parameter mismatch before attempting a start. [S04]

If another build is pending/running, refresh and follow it rather than issuing duplicate starts. A network failure after a start POST is ambiguous: first fetch the latest build before retrying the POST, because the server may already have accepted it. Never retry stop/delete/update operations as part of a generic connect loop.

### 6.2 Readiness has multiple layers

A successful provisioner build is not sufficient. A “connected” agent is not necessarily finished with startup scripts. Check these independently:

| Layer | State being checked |
|---|---|
| Workspace/build | The desired start build completed and has usable resources. |
| Agent connection | `status` is `connected`, rather than `connecting`, `disconnected`, or `timeout`. |
| Agent lifecycle | Startup waiting policy permits login. |
| Tailnet | The selected peer is actually reachable through the network engine. |
| SSH | The virtual TCP stream opens and an SSH handshake succeeds. |

Agent lifecycle values include `created`, `starting`, `start_timeout`, `start_error`, `ready`, `shutting_down`, `shutdown_timeout`, `shutdown_error`, and `off`. Do not treat every value other than `ready` as an endless transient wait. [S05]

The official CLI supports a wait policy equivalent to `yes`, `no`, and `auto`; `auto` checks whether any agent script has `start_blocks_login=true`. An implementation SHOULD follow this distinction. A startup error/timeout should produce a specific result and relevant logs, with an explicit user option to attempt diagnostic login where server policy permits it. Do not silently claim a failed startup succeeded. [S05, S16]

Suggested client defaults are a bounded REST request deadline, a separately configurable build/startup deadline, and a separately configurable network-dial deadline. For example: 20 seconds per REST request, 10 minutes for build/startup, and 120 seconds for initial tailnet establishment. These values are product decisions, not protocol limits.

### 6.3 Polling versus watches

A correct MVP can poll the workspace and selected agent with backoff and cancellation. Re-read the workspace when its build changes, then resolve the agent again. Never continue indefinitely with an agent ID from a superseded build.

The reference SDK also offers a text-JSON WebSocket:

```text
/api/v2/workspaces/{workspaceID}/agent-connection-watch?agent_name=main
```

`ConnectionWatchEvent` contains an optional `error`, `build_update`, or `agent_update`. Build updates contain `transition` and `job_status`; agent updates contain `id` and `lifecycle`. Watch errors include a numeric code, `retryable`, `message`, and optional `details`. Codes are: too many agents `1`, name not found `2`, no agents `3`, server shutdown `4`, database `5`, internal `6`. [S18]

This watch is a readiness/discovery facility, not the tailnet coordinator. It carries text JSON, whereas tailnet coordination carries a binary multiplexed protocol. Support polling as a compatibility fallback rather than assuming all historical servers expose this watch.

## 7. Connection information and DERP map

The agent-specific connection response is:

```go
type AgentConnectionInfo struct {
    DERPMap                  *tailcfg.DERPMap `json:"derp_map"`
    DERPForceWebSockets       bool             `json:"derp_force_websockets"`
    DisableDirectConnections bool             `json:"disable_direct_connections"`
    HostnameSuffix           string           `json:"hostname_suffix,omitempty"`
}
```

The outer fields are Coder JSON fields. The nested REST DERP map uses the Tailscale `tailcfg.DERPMap` JSON representation. It is **not** the same field spelling/shape as the protobuf `DERPMap` used by the coordinator stream. Use the SDK's conversion routines rather than assuming the two encodings are interchangeable. [S06, S09, S15]

A synthetic reduced response illustrates the difference:

```json
{
  "derp_map": {
    "Regions": {
      "999": {
        "RegionID": 999,
        "EmbeddedRelay": true,
        "RegionCode": "example",
        "RegionName": "Example relay",
        "Nodes": [
          {
            "Name": "999a",
            "RegionID": 999,
            "HostName": "coder.example.test",
            "DERPPort": 443,
            "STUNPort": 3478
          }
        ]
      }
    }
  },
  "derp_force_websockets": false,
  "disable_direct_connections": false,
  "hostname_suffix": "coder"
}
```

The numbers and names above are examples, not constants to hard-code.

Required handling:

1. Use the supplied DERP map, including region/node selection and port configuration.
2. Apply server `disable_direct_connections` even when the user prefers direct connectivity. The effective policy is server restriction **OR** user relay-only preference.
3. Honor `derp_force_websockets`; it is distinct from relay-only mode. Relay-only can use DERP's ordinary HTTP upgrade unless WebSockets are separately required.
4. Apply subsequent map updates from `StreamDERPMaps`.
5. Preserve the SDK's rewrite of the embedded/default relay to the actual client-facing deployment URL. Do not rewrite unrelated third-party relay nodes indiscriminately.
6. Configure trust roots and any approved reverse-proxy authentication for both coordination and relay traffic. Do not assume a REST-only HTTP customization covers every relay transport automatically. [S06–S07, S14–S15]

The ordinary SDK SSH path does not require installing Coder Connect or making the hostname suffix resolve in the OS. The CLI contains a separate optimization that tries an already-installed Coder Connect path on port 22; it otherwise uses `DialAgent`. [S16]

## 8. Tailnet coordination: WebSocket, Yamux, DRPC

### 8.1 HTTP upgrade

Independent clients establish a WebSocket at:

```http
GET /api/v2/workspaceagents/{agentID}/coordinate?version=2.0 HTTP/1.1
Host: coder.example.test
Coder-Session-Token: <token>
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: <generated-by-WebSocket-library>
```

Use `wss` for a production HTTPS deployment. The ordinary coordinator dialer does not set the DERP WebSocket subprotocol. Compression is disabled by the Coder workspace SDK. The upgraded connection is treated as a stream of **binary WebSocket payload bytes**. Message boundaries are not application message boundaries. [S06–S07]

The server checks database availability, SSH authorization, native-client policy, and protocol version before it upgrades. It assigns a fresh coordinator peer UUID or recovers one from a valid `resume_token` query parameter. The route's coordinator authorization is scoped through `ClientCoordinateeAuth{AgentID: selectedAgent}`. This is not an unrestricted Tailscale control-plane registration API. [S09]

Always explicitly supply the tailnet protocol version. The server's omitted-version fallback is not the modern SDK's negotiated path. Do not confuse:

- Coder release version, such as `v2.36.4`;
- REST API namespace `/api/v2`;
- tailnet control protocol `version=2.0`;
- the agent's separate reported API/version metadata. [S05–S07, S09]

### 8.2 Layering and concurrency

The exact control stack is:

```text
HTTPS/WSS connection
  binary WebSocket byte stream
    HashiCorp Yamux client session
      one Yamux stream per DRPC invocation/stream
        DRPC request/response framing
          protobuf-encoded coder.tailnet.v2 messages
```

`tailnet.NewDRPCClient` constructs `yamux.Client` using default Yamux configuration, then `drpcsdk.MultiplexedConn(session)`, then the generated Tailnet DRPC client. The server uses `yamux.Server` and serves DRPC on accepted streams. [S11–S13]

The multiplexing wrapper opens a fresh Yamux stream for each DRPC unary invocation and for each streaming RPC. This allows the long-lived coordinate and DERP-map streams to coexist with resume-token refreshes. It is not one sequential RPC connection that blocks all other calls while `Coordinate` remains open. [S12]

The reference wrapper sets a DRPC reader maximum buffer of **4 MiB**. Its named default Yamux stream window is **256 KiB**. Neither value limits the total size of an SSH file transfer: SSH file data does not flow through the coordinator RPC payloads. [S12]

A client MUST NOT send JSON, gRPC-over-HTTP/2 frames, bare protobuf messages, or SSH bytes directly to this WebSocket. Reuse compatible Yamux and DRPC implementations, or implement their actual framing and flow control before implementing the protobuf service.

### 8.3 RPC methods

The generated RPC names and stream semantics are:

| RPC name | Request/response semantics | Needed for single-agent SSH? |
|---|---|---|
| `/coder.tailnet.v2.Tailnet/Coordinate` | Bidirectional `CoordinateRequest` / `CoordinateResponse` | Yes |
| `/coder.tailnet.v2.Tailnet/StreamDERPMaps` | Empty request, server stream of `DERPMap` | Yes, for normal SDK-equivalent behavior |
| `/coder.tailnet.v2.Tailnet/RefreshResumeToken` | Empty request, unary token response | Recommended; optional for interoperability |
| `/coder.tailnet.v2.Tailnet/PostTelemetry` | Unary telemetry batch | No |
| `/coder.tailnet.v2.Tailnet/WorkspaceUpdates` | Owner request, server stream of workspace/agent updates | No |

For `StreamDERPMaps`, the generated client sends an empty protobuf request and then closes its **send side**, while continuing to receive maps. For `Coordinate`, both directions remain open. These half-close semantics matter when implementing DRPC independently. [S10, S26]

The stock single-agent dialer requests tailnet **2.0** for broad compatibility. It requests **2.3** when workspace-update streaming is enabled. Comments in the dialer identify telemetry and resume tokens as optional extensions that tolerate unsupported older servers. Do not require the optional RPCs to succeed merely to establish a basic SSH connection. [S07]

### 8.4 Coordinate request fields

The actual schema uses the following field numbers; these are not a JSON protocol and not a `oneof` declaration:

| `CoordinateRequest` field | Tag | Content |
|---|---:|---|
| `update_self` | 1 | Nested `UpdateSelf`, whose `node` field has tag 1. |
| `disconnect` | 2 | Empty nested message for graceful coordinator disconnect. |
| `add_tunnel` | 3 | Nested `Tunnel`, whose `id` field has tag 1 and contains the destination agent UUID as bytes. |
| `remove_tunnel` | 4 | Same nested tunnel structure. |
| `ready_for_handshake` | 5 | Repeated nested acknowledgements, each with peer UUID bytes in field 1. |

Use the original `.proto` file as the code-generation input instead of transcribing this table into a divergent schema. An implementation can send separate semantic operations in separate requests to simplify concurrency. [S10]

The client publishes its own node information and requests a tunnel to the selected agent. Node changes—such as new endpoints or preferred relay—must continue to be published. A one-time registration followed by ignoring coordination updates is insufficient.

The destination's ready-for-handshake acknowledgement exists to avoid beginning WireGuard handshakes before the destination has received/configured the source node. Use Coder's source/destination coordination controllers and peer-update application rather than treating initial receipt of a public key as the entire readiness protocol. [S10, S06]

### 8.5 Coordinate responses

`CoordinateResponse` has `peer_updates` at tag 1 and a string `error` at tag 2. Each peer update contains:

| Field | Tag | Representation |
|---|---:|---|
| `id` | 1 | Peer UUID, 16 raw bytes. |
| `node` | 2 | Node information, when applicable. |
| `kind` | 3 | Enum below. |
| `reason` | 4 | Human-readable reason. |

Kinds are `UNSPECIFIED=0`, `NODE=1`, `DISCONNECTED=2`, `LOST=3`, and `READY_FOR_HANDSHAKE=4`. Do not discard every kind except `NODE`. In an SDK-based implementation, peer updates belong in the existing coordination controller/`tailnet.Conn.UpdatePeers` path. An independent port must mirror the upstream handling of loss, removal, and handshake readiness rather than inventing a single “peer offline” boolean. [S10, S14]

### 8.6 Node serialization and a critical key-format distinction

| `Node` field | Tag | Type / meaning |
|---|---:|---|
| `id` | 1 | `int64` network Node ID. |
| `as_of` | 2 | Protobuf timestamp. |
| `key` | 3 | **34 bytes:** ASCII `np` followed by the 32 raw node-public-key bytes. |
| `disco` | 4 | `discokey:` followed by the 64 hexadecimal characters of the discovery public key. |
| `preferred_derp` | 5 | `int32` preferred/home DERP region. |
| `derp_latency` | 6 | Map from string keys to double values. Preserve upstream semantics. |
| `derp_forced_websocket` | 7 | Map from region IDs to diagnostic strings. |
| `addresses` | 8 | Repeated textual IP prefixes, normally a client `/128`. |
| `allowed_ips` | 9 | Repeated textual IP prefixes. |
| `endpoints` | 10 | Repeated endpoint strings supplied by the network engine. |

Coder calls `NodePublic.MarshalBinary()` and `DiscoPublic.MarshalText()`. The pinned Tailscale implementation defines the binary node prefix as `np` and the disco text prefix as `discokey:`. **Do not put just 32 bytes into protobuf `Node.key`; do not put `nodekey:<hex>` there either.** [S10, S15, S21–S22]

Conversely, DERP's packet-address fields use the **raw 32-byte** public key, without the `np` prefix. The two representations refer to the same underlying key but are not wire-interchangeable. [S21, S23]

UUIDs inside protobuf fields are 16 raw bytes, not UTF-8 UUID strings. The REST API uses string UUIDs. Protobuf JSON's base64 convention for `bytes` is not the binary DRPC representation. [S15, S26]

### 8.7 Resume-token behavior

`RefreshResumeTokenResponse` contains `token` at tag 1, `refresh_in` as a protobuf duration at tag 2, and `expires_at` as a timestamp at tag 3. Refresh according to the server's returned schedule, rather than hard-coding token validity. [S10, S13]

On a coordinator reconnect, append `resume_token=<url-encoded-token>` when available. If the HTTP error's `validations` array identifies field `resume_token`, discard that resume token and retry without it. The server explicitly uses HTTP 401 for an invalid resume token, so “every 401 means the user must log in” is wrong. [S07, S09]

A resume token recovers coordinator peer identity. It does not re-create a lost userspace TCP stack, a terminated SSH session, or a shell process. Preserve the network engine when reconnecting the control channel where the upstream controller supports it; never promise that all network failures are transparent to SSH.

### 8.8 Logical end-to-end exchange

The following is a logical sequence, not a captured packet trace. Several activities overlap, and map/node updates continue asynchronously. The SDK orchestrates these steps. [S06–S15]

```text
Client                           Coder control plane                  Agent
  | GET user/workspace/agent ---------> |                                |
  | <----------- metadata ------------ |                                |
  | GET agent connection info -------> |                                |
  | <------- DERP map/policies -------- |                                |
  |                                    |                                |
  | create userspace engine, node key, disco key, local virtual /128      |
  |                                    |                                |
  | WSS coordinate?version=2.0 -------> |                                |
  | <---------- HTTP 101 -------------- |                                |
  | Yamux + DRPC Coordinate ---------- |                                |
  | DRPC StreamDERPMaps -------------- |                                |
  | <------- initial/new maps --------- |                                |
  | update_self(local Node) ---------> |                                |
  | add_tunnel(agent UUID bytes) -----> |                                |
  |                                    | ---- authorized peer update -> |
  | <------- peer Node/update -------- | <----- agent Node/readiness --- |
  | apply keys/routes/handshake-readiness via coordination controllers    |
  |                                    |                                |
  | <======= WireGuard over direct UDP or DERP relay ==================> |
  | ------- virtual TCP connect to agent-derived IPv6, port 1 ---------> |
  | <================== ordinary SSH byte stream =====================> |
  | POST workspace usage -----------> |                                |
  |                                    |                                |
  | close SSH, stop usage, close coordination/network on session end     |
```

The workspace agent's own registration/control connection already exists as part of the provisioned workspace. The user client must not try to establish that agent-side connection using an agent credential.

## 9. Virtual network addressing

The ordinary single-agent SDK path uses the service prefix:

```text
fd7a:115c:a1e0::/48
```

The agent's virtual IPv6 address is computed by taking its UUID's 16 bytes and replacing the first six bytes with:

```text
fd 7a 11 5c a1 e0
```

For example, the synthetic agent UUID:

```text
00112233-4455-6677-8899-aabbccddeeff
```

maps to:

```text
fd7a:115c:a1e0:6677:8899:aabb:ccdd:eeff
```

The SDK uses `tailnet.TailscaleServicePrefix.AddrFromUUID(agentID)`. A client's own address is generated from a fresh random UUID with the same prefix and advertised as `/128`. This address is not the coordinator-assigned peer UUID. [S06, S08, S14]

The reference also defines `CoderServicePrefix`, `fd60:627a:a42b::/48`, for an ongoing migration associated with OS-integrated networking. Do not independently substitute that prefix into the existing SDK SSH algorithm; use the prefix selected by the compatible SDK. [S14]

These addresses live in the userspace overlay. Calling the operating system's ordinary `net.Dial` on the address will not reproduce `tailnet.Conn.DialContextTCP` unless a separate OS-level VPN integration has installed the appropriate connectivity. The physical network can be IPv4 even though the virtual peer address is IPv6.

## 10. Data plane: direct paths, DERP, and virtual TCP

### 10.1 Network-engine responsibilities

Coder creates a fresh node private key, a userspace WireGuard engine, a Tailscale magicsock transport, and a gVisor-backed network stack. The engine discovers and publishes usable endpoints, processes authenticated discovery, configures authorized peer keys/routes, and chooses direct or relay paths. The application does not need root privileges just to obtain the SDK's userspace connection. [S14]

The conceptual encapsulation for actual SSH traffic is:

```text
SSH protocol bytes
  TCP stream
    virtual IPv6 packets
      WireGuard encrypted packets
        direct UDP
        OR DERP packet payloads carried over a relay connection
```

Do not send an SSH banner as a DERP packet. DERP supplies packet transport, not a reliable SSH byte stream by itself. Removing direct-path support does not remove the need for WireGuard and a virtual TCP/IP stack.

For direct connectivity, the engine uses advertised endpoints and discovery/NAT-traversal mechanisms. It may use a relay during setup or when a direct path is unavailable. The application SHOULD expose diagnostics indicating relay/direct use, but SHOULD NOT assume a fixed ordering or delay before the selected path changes. [S14, D02]

### 10.2 DERP HTTP transport

The inspected fork constructs the relay URL from a DERP map node, ordinarily using path `/derp` and the node's host/port information. Do not assume every relay is the main deployment host or always listens on 443. Non-production HTTP flags and test-only TLS exceptions exist upstream; they are not appropriate production defaults. [S24]

Ordinary DERP transport performs an HTTP/1.1 upgrade:

```http
GET /derp HTTP/1.1
Host: <selected-relay-host>
Connection: Upgrade
Upgrade: DERP
```

In the ordinary non-fast-start path, the client expects HTTP `101 Switching Protocols` and then speaks the DERP binary framing below over the upgraded stream. This is **not** an RFC WebSocket framing layer. The reference client also has a TLS metadata-certificate fast-start optimization; a new implementation using the upstream library inherits it, while an independent implementation can initially use the standard upgrade path. [S24]

HTTP/2 ALPN and proxies that do not support the custom upgrade can disrupt this path. The fork detects certain failures and enables its WebSocket fallback for the next attempt. The deployment can also require WebSockets from the outset. [S24]

### 10.3 DERP WebSocket transport

The alternative is a WebSocket to the selected relay's `/derp` URL with:

```http
Sec-WebSocket-Protocol: derp
```

The stock helper adapts binary WebSocket messages into a byte stream and then runs the **same DERP client protocol** over it. Thus the two WebSockets used by Coder have very different stacks:

```text
Coordinator WSS:  WebSocket → Yamux → DRPC → protobuf coordination
Relay WSS:        WebSocket → DERP frames → encrypted network packets
```

The DERP helper intentionally avoids writing diagnostic output where it could corrupt SSH output. A custom implementation must preserve that property throughout its dependency logging. [S25]

### 10.4 DERP frame layout

The pinned DERP implementation uses protocol version 2. Every frame begins with:

```text
1 byte  frame type
4 bytes payload length, unsigned big-endian, excluding these 5 header bytes
N bytes payload
```

Selected client-relevant frame types:

| Type | Name | Payload |
|---:|---|---|
| `0x01` | Server key | 8-byte `DERP🔑` magic, 32-byte server public key, possibly future extension bytes. |
| `0x02` | Client info | 32-byte client public key, 24-byte nonce, NaCl-box-encrypted client-info JSON. |
| `0x03` | Server info | 24-byte nonce and NaCl-box-encrypted server-info JSON. |
| `0x04` | Send packet | 32-byte destination node public key, followed by packet bytes. |
| `0x05` | Receive packet | In protocol v2: 32-byte source node public key, followed by packet bytes. |
| `0x06` | Keepalive | Empty/no-op payload. |
| `0x07` | Note preferred | One byte: whether this is the client's home/preferred relay. |
| `0x08` | Peer gone | 32-byte peer public key and a reason byte. |
| `0x12` | Ping | 8 bytes to echo. |
| `0x13` | Pong | Echo of the ping payload. |
| `0x14` | Health | Text describing/clearing a connection health condition. |
| `0x15` | Restarting | Two big-endian uint32 millisecond durations describing reconnect timing. |

The normal exchange is server-key → client-info → server-info, then packet and maintenance frames. The DERP public-key fields are raw 32-byte values, not protobuf `Node.key`'s `np`-prefixed encoding. The packet-size constant is 64 KiB excluding DERP framing overhead. These bounds are not SSH-file-size limits. [S21, S23]

Use `derp.NewClient`/`derphttp` for client-info cryptography, JSON details, maintenance frames, bounds checking, and reconnect behavior. Mesh-only operations such as forwarding/watching other relay nodes are not needed by this client. The Coder login token is not embedded in the DERP packet header; approved HTTP reverse-proxy credentials are a separate concern. [S23–S25]

### 10.5 Trust model

The Coder coordinator is trusted to authorize and introduce the correct peer key. WireGuard protects client-to-agent traffic even when a DERP relay carries it. The relay transport's TLS protects its connection as well, but it is not a substitute for the inner WireGuard encryption.

Do not describe this arrangement as protecting against a malicious Coder control plane while simultaneously following the SDK's policy of not independently checking the SSH host key. Independent SSH host-key pinning is a possible additional policy, not the stock SDK trust model. [S08–S09, S14]

## 11. SSH connection semantics

### 11.1 Which port is used?

For the ordinary workspace SDK:

```text
destination = TailscaleServicePrefix.AddrFromUUID(agentID)
virtual TCP port = 1
```

`AgentConn.SSH(ctx)` delegates to `SSHOnPort(ctx, tailnet.WorkspaceAgentSSHPort)`, whose value is `1`. It returns a gVisor TCP connection. [S08, S14]

The source also defines `WorkspaceAgentStandardSSHPort=22`, and the CLI's separate Coder Connect path uses port 22. **Do not infer that port 22 necessarily means a separately installed host OpenSSH daemon.** For this implementation, use `AgentConn.SSH()` unless deliberately adding another connection mode. [S14, S16]

`AgentConn.DialContext` extracts the requested port and directs the connection to the selected agent; it is not a general-purpose dialer for arbitrary external destination hostnames. Use SSH `direct-tcpip` forwarding when the desired semantics are a connection made from the workspace's environment to another host. [S08]

### 11.2 Authentication inside SSH

The built-in agent SSH server configures `NoClientAuth: true`. The SDK's `SSHClient` creates an SSH client connection without an additional SSH password/private-key authentication configuration and uses `ssh.InsecureIgnoreHostKey()`. Authorization has already happened through Coder's authenticated network setup. [S08, S17]

This does **not** mean arbitrary network clients can normally reach the workspace without credentials. It means the private stream returned by the authorized Coder transport is the access boundary.

Do not ask the user to download a Git SSH private key or expose an agent credential as part of this flow. Do not treat an SSH username such as `root` as a supported instruction to change the agent's execution identity. The agent server launches sessions through its configured execution/environment machinery; the expected user must be verified against the workspace template's actual environment. [S17]

The string `localhost:22` in the SDK's `ssh.NewClientConn` call is an SSH library connection label, **not evidence that the SDK dialed localhost port 22**. The preceding virtual network dial targets the selected agent and configured virtual SSH port. [S08]

### 11.3 Raw stream versus native SSH client

Choose one of these paths for each connection:

**Raw transport:** `AgentConn.SSH()` returns bytes for OpenSSH or another SSH implementation. The adapter must not perform its own SSH handshake on that stream before handing it to the downstream SSH client.

**Native SSH implementation:** `AgentConn.SSHClient()` returns an authenticated Go SSH client. Alternatively, wrap `AgentConn.SSH()` with a deliberately configured SSH library client to implement a different host-key or handshake-timeout policy. Do not call both helpers and assume they refer to the same underlying connection. [S08]

For a native terminal implementation, support session creation, a PTY request when interactive, the initial terminal type and dimensions, resize events, stdin, stdout/stderr semantics, shell/exec requests, signals where supported, exit status, and cancellation. A noninteractive command should normally run without a PTY so output streams and bytes are not transformed.

Using a raw adapter with an established SSH client avoids reimplementing those SSH features. The agent registers session, SFTP, direct TCP, reverse TCP, and stream-local facilities, but policy can block file transfer or forwarding. Tests must verify permitted behavior and correct handling of server denials, not bypass them. [S17]

### 11.4 Host-key policy for an OpenSSH adapter

A narrowly scoped POSIX configuration can use the same trust model as the SDK:

```sshconfig
Host coder-dev
    HostName coder-dev.invalid
    User coder
    ProxyCommand /absolute/path/coder-ssh-client proxy --profile home --workspace dev --agent main
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    CheckHostIP no
    ForwardAgent no
```

This is an illustrative configuration for the proposed executable, not a command that exists upstream. `User coder` is an example SSH username, not a requested privilege change. The fake hostname is not resolved through ordinary networking because ProxyCommand supplies the stream.

The host-key exception MUST be confined to the exact generated Coder aliases and authorized transport. Never install these settings under `Host *`, apply them to the Coder HTTPS connection, or reuse them for an ordinary public SSH host. Non-POSIX platforms need appropriate known-hosts file handling rather than a literal `/dev/null` assumption.

A product may instead offer explicit additional host-key pinning, with a documented policy for valid key changes and rebuilds. That is distinct from claiming the stock SDK already checks a Coder-provided SSH host-key certificate.

### 11.5 Browser PTY is not an SSH substitute

Coder exposes a separate reconnecting-PTY WebSocket at `/api/v2/workspaceagents/{agentID}/pty`. Its parameters include reconnect ID, terminal size, and command. The SDK's PTY interface sends structured terminal input/resize data and receives terminal output. This does not expose the SSH transport protocol. [S06, S08]

Implementing that endpoint may produce a working terminal but will not satisfy a request for ordinary SSH, SSH subsystems, or SSH forwarding. Do not use the browser PTY API as a shortcut and label it an SSH client.

## 12. SDK integration and dependency requirements

### 12.1 Connection-core sketch

This sketch deliberately begins with an already configured API client and an already resolved current-build agent UUID. It omits profile storage, discovery, startup policy, usage monitoring, and stream pumping, which are specified elsewhere.

```go
package codertransport

import (
    "context"
    "errors"
    "fmt"
    "net"
    "sync"

    "github.com/coder/coder/v2/codersdk"
    "github.com/coder/coder/v2/codersdk/workspacesdk"
    "github.com/google/uuid"
)

// SSHTransport owns both a raw SSH stream and its Coder network connection.
// The caller must call Close, including when the session context is canceled.
// The concrete Stream also supports TCP half-close; a pump can type-assert
// interface { CloseWrite() error } when its input reaches EOF.
type SSHTransport struct {
    Stream net.Conn
    agent  workspacesdk.AgentConn
    once   sync.Once
    err    error
}

func OpenSSHTransport(
    dialCtx context.Context,
    client *codersdk.Client,
    agentID uuid.UUID,
    relayOnly bool,
) (*SSHTransport, error) {
    if client == nil || agentID == uuid.Nil {
        return nil, errors.New("API client and nonzero agent ID are required")
    }

    agent, err := workspacesdk.New(client).DialAgent(
        dialCtx,
        agentID,
        &workspacesdk.DialAgentOptions{BlockEndpoints: relayOnly},
    )
    if err != nil {
        return nil, fmt.Errorf("establish Coder agent network: %w", err)
    }

    stream, err := agent.SSH(dialCtx)
    if err != nil {
        _ = agent.Close()
        return nil, fmt.Errorf("open agent SSH stream: %w", err)
    }

    return &SSHTransport{Stream: stream, agent: agent}, nil
}

func (t *SSHTransport) Close() error {
    if t == nil {
        return nil
    }
    t.once.Do(func() {
        t.err = errors.Join(t.Stream.Close(), t.agent.Close())
    })
    return t.err
}
```

The method names and ownership model are taken from the reference SDK. This sketch is not asserted to be compiled/tested. The implementing agent must validate it with the pinned module graph and its chosen platform. [S06, S08]

Configure the API client with `codersdk.New(serverURL, codersdk.WithSessionToken(token))` and appropriate HTTP/TLS options. The older `SetSessionToken` method still exists in the reference but is deprecated in favor of creating a client with the token option. A fresh client per credential generation avoids unsafe mutations of shared authentication state. [S02]

If supplying logs, use the SDK's expected `cdr.dev/slog/v3` logger, not an incompatible assumption that every `slog` name means Go's standard-library `log/slog` type. Keep SDK and network-library logging out of stdout. [S06, S14]

### 12.2 What `DialAgent` supplies

`DialAgent` already handles the main network setup:

- Fetching agent-specific connection information and honoring server relay/direct policy.
- Setting up authenticated WebSocket dial options.
- Creating the userspace tailnet and embedded-relay map rewriting.
- Creating the controller, resume-token controller, DERP-map controller, and source coordination controller.
- Adding the selected agent as a tunnel destination.
- Establishing control-plane streams and waiting for peer reachability.
- Coupling controller/network cleanup to `AgentConn.Close()`. [S06]

Do not implement a second competing coordinator beside it for the same connection unless deliberately replacing the SDK. Workspace lookup, user interaction, startup policy, and usage/error presentation remain application responsibilities.

### 12.3 Pin the whole dependency graph, not only the SDK import

The reference Coder module declares **Go 1.26.5**. Match the reference toolchain or a verified compatible newer toolchain for the initial implementation. Do not assume an older installed Go compiler can build the release unchanged. [S19]

Coder's `go.mod` uses forks/replacements for important networking dependencies. Critical examples are:

```gomod
replace tailscale.com => github.com/coder/tailscale v1.1.1-0.20260529105257-b7c5fc6e6399
replace github.com/tailscale/wireguard-go => github.com/coder/wireguard-go v0.0.0-20260113101225-9b7a56210e49
replace gvisor.dev/gvisor => github.com/coder/gvisor v0.0.0-20260313164934-7a658db7b714
replace github.com/gliderlabs/ssh => github.com/coder/ssh v0.0.0-20231128192721-70855dedb788
```

This is a **critical subset**, not a promise that these are the only replacements needed by the selected imports. Read the complete pinned `go.mod`; propagate the applicable replacements into the new client's main module and retain a reproducible `go.sum`. The Go module system does not inherit dependency-module replacement directives as though they were the importing module's directives. [S19, G01]

A practical implementation sequence is to prove the connection core against the pinned Coder dependency graph first, then extract a standalone module and prune unnecessary dependencies only after builds and tests pass. Do not “fix” missing Coder-specific Tailscale methods by replacing the fork with arbitrary upstream latest packages.

Review source and dependency license requirements before distributing an embedded/forked client. This document does not resolve license obligations for a particular distribution model.

## 13. Proposed application interfaces

The transport core SHOULD have no terminal UI and no dependence on global command-line configuration. Suggested boundaries are:

```text
CredentialStore
  Load(profile) -> credential + identity/generation metadata
  SaveValidated(profile, credential, identity) -> generation

WorkspaceResolver
  Resolve(identifier) -> workspace
  SelectAgent(workspace, explicit selector) -> agent or ambiguity error
  EnsureReady(start policy, wait policy, deadline) -> refreshed workspace + agent

ConnectionManager
  OpenSSH(profile, workspaceID, current agentID, options) -> owned SSH stream
  Close(connection)
  Events() -> structured lifecycle/auth/network diagnostics

Adapters
  Raw-stdio ProxyCommand
  Native SSH/terminal integration
  Optional authenticated gateway frontend
```

An illustrative CLI contract is:

```text
coder-ssh-client login --profile home --url https://coder.example.test
coder-ssh-client workspaces --profile home
coder-ssh-client agents --profile home --workspace dev
coder-ssh-client proxy --profile home --workspace dev --agent main
coder-ssh-client proxy --profile home --workspace dev --agent main --start --wait auto
coder-ssh-client proxy --profile home --workspace dev --agent main --relay-only
```

These are proposed commands, not existing Coder commands. The login command may accept a deliberately selected secure stdin/file mechanism for automation; the proxy command's stdin belongs exclusively to SSH.

Configuration SHOULD include deployment URL, credential reference, workspace identifier, optional agent selector, start/wait policies, per-phase deadlines, direct/relay preference, TLS trust configuration, logging level, and whether optional usage/telemetry is enabled. It MUST NOT dump tokens into normal JSON status output.

Structured diagnostics should include phase, error class, safe HTTP status, deployment/profile identifier, workspace/build/agent IDs, and whether the connection is direct or relayed when known. Do not log full authenticated request URLs, headers, terminal contents, or unredacted response bodies.

## 14. Lifetime, cancellation, usage, and reconnect behavior

### 14.1 Separate dial lifetime from session lifetime

The reference `DialAgent` uses an internal ongoing connection context separate from the caller's initial dial context. Canceling an expired setup deadline is not the same as closing an established agent network. The returned `AgentConn` must be explicitly closed. [S06]

The application therefore needs two lifetimes:

```text
setup deadline: resolve → readiness → DialAgent → SSH TCP stream
session lifetime: SSH exchange/pumping until EOF, explicit disconnect, or cancellation
```

Cancel the setup deadline after successful establishment. Keep the session alive until its own owner closes it. On a session cancellation, actively close the raw stream and agent connection to unblock I/O. Do not wait forever for a goroutine whose read cannot otherwise be interrupted.

Avoid an indiscriminate short `http.Client.Timeout` on a shared client that also handles long-lived WebSockets. Use bounded request/dial contexts and separate per-phase deadlines. A native SSH handshake should also have a bounded deadline that is cleared after successful establishment.

### 14.2 Raw-stdio pump requirements

Run independent bounded-memory copies for stdin → SSH and SSH → stdout. Preserve bytes exactly: no line decoding, newline conversion, UTF-8 assumptions, banners, or prompt text.

On normal stdin EOF, half-close the SSH stream's write direction when supported and continue reading remaining remote output. Do not immediately destroy the tailnet and truncate command output. On cancellation or a fatal read/write failure, close the stream so the other copy unblocks, then close the owning agent connection. Ensure the process can terminate even when its inherited stdin remains blocked.

The caller should receive meaningful transport failure status. The downstream SSH client, not a raw proxy, owns interpreting the remote command's SSH exit-status message. Do not mistake normal local pipe shutdown for a remote command failure or replay an exec request after uncertain delivery.

### 14.3 Usage reporting

For actual active SSH usage, the current CLI invokes the SDK with:

```http
POST /api/v2/workspaces/{workspaceID}/usage
Content-Type: application/json
Coder-Session-Token: <token>

{
  "agent_id": "44444444-4444-4444-8444-444444444444",
  "app_name": "ssh"
}
```

Expected success is HTTP 204. `UpdateWorkspaceUsageWithBodyContext` performs an initial update and then repeats every minute until its returned cleanup function is called or its context ends. [S04, S16]

Usage reporting is separate from network telemetry. It should reflect a real active connection and stop when the connection ends. Do not promise that it overrides every autostop policy, and do not silently disable workspace TTL or repeatedly call the explicit deadline-extension endpoint to keep an unused workspace alive.

The SDK usage helper logs failures rather than exposing a structured authentication-loss channel. A product that needs reliable credential-expiry UX should implement monitored usage/API requests or another explicit identity check rather than relying only on this helper's logs. A failed optional usage call is not by itself proof that SSH authorization has disappeared.

### 14.4 Reconnect the right layer

There are at least three different failures:

| Failure | Appropriate response |
|---|---|
| Coordinator connection drops | Let the controller reestablish control streams and resume peer identity where possible. |
| Direct or relay path changes | Let the network engine discover/reconnect paths; preserve the userspace stack where possible. |
| SSH TCP session is irrecoverably closed or agent process restarted | End that SSH connection; create a new connection only at the user's/application's intended retry boundary. |

A control-channel reconnect is not an instruction to re-run a command. Never automatically replay non-idempotent remote commands. A terminal multiplexer inside the workspace can preserve interactive work, but that is application/session behavior, not a guarantee supplied by a tailnet resume token.

The reference tailnet exposes `Rebind()` to reset local bindings and rediscover paths. A native application may use supported network-change/wake integration, but should not implement an unbounded reconnect storm on every transient event. [S14]

### 14.5 Authentication loss after initial connection

The SDK's initial dial error is not a complete mid-session authentication notification mechanism. Coordination reconnects and other work happen within ongoing controllers. An application requiring explicit expired-token handling MUST observe authenticated control requests after initial connection.

Recommended policy:

1. Classify the error source. An invalid coordinator `resume_token` has its own retry path.
2. For a genuine primary Coder API 401, confirm through an appropriate fresh authenticated request when needed; distinguish an authenticating reverse proxy or insufficient scope from an expired user session.
3. Mark the credential generation `AuthRequired`; stop creating new agent connections with it.
4. Request replacement credentials only through the login/control UI, never inside the raw SSH stream.
5. Validate the replacement token and expected user identity using a fresh client.
6. Persist atomically, create a new credential generation, and establish subsequent connections with a fresh network/controller instance.

Whether the product immediately closes an existing SSH connection on confirmed authentication loss is an explicit client policy. It should generally fail closed for gateways and managed security-sensitive clients. **Do not claim upstream token expiry necessarily tears down every already-established data-plane connection at the exact expiry instant.**

## 15. Error classification

Decode Coder error bodies, including their `message`, `detail`, and `validations`, before reducing them to a user-facing error class. Preserve useful context without leaking secrets. [S07, S09]

| Observation | Classification/action |
|---|---|
| HTTP 401 with validation field `resume_token` from coordination | Discard resume token; retry without it. Do not invalidate the user's login token. |
| Genuine authentication 401 from primary REST/coordinator request | Enter authentication-required flow. Do not spin forever on the same token. |
| HTTP 403 | Permission/policy failure; do not assume re-entering an identical token will fix it. |
| HTTP 404 from agent/coordination | Missing/stale agent or authorization-hidden resource. Refresh current build when appropriate; do not assert the resource does not exist globally. |
| HTTP 400 with `version` validation | Tailnet protocol incompatibility. Report server/client versions and supported path; no blind major-version downgrade. |
| Other HTTP 400 | Invalid request or unsupported action/state. Surface field details; do not blindly retry. |
| HTTP 409 | Inspect the specific state/policy conflict. Retry only after a relevant state change, not universally. |
| HTTP 429 | Respect retry guidance and apply bounded, jittered backoff. |
| HTTP 5xx or transient DNS/connect failures | Bounded retries with cancellation. For a prior mutation, check whether it took effect before retrying. |
| HTML login page or unexpected cross-origin redirect | Reverse-proxy/SSO or wrong-origin problem. Do not forward credentials indiscriminately or label it a protobuf bug. |
| Agent connected but startup not ready | Apply startup wait policy and show startup diagnostics. |
| Peer introduced but unreachable | Report a transport failure with relay/direct/TLS/endpoint diagnostics, not “invalid password.” |
| SSH handshake/session request rejected | Separate SSH/service policy failure from Coder login failure. |
| Agent replaced in a new build | Re-resolve the selected agent before a new connection. Do not silently switch an active SSH stream to another destination. |

The reference CLI has bounded per-step retries for transient HTTP/network errors. The dialer's first-connection error classification and the outer CLI's retry logic are separate layers; copying one status list without its surrounding behavior can lead to incorrect retry decisions. [S07, S16]

Suggested application error classes are `InvalidConfiguration`, `AuthRequired`, `PermissionDeniedOrNotFound`, `AmbiguousAgent`, `WorkspaceNotReady`, `StartupFailed`, `UnsupportedProtocol`, `TransportUnavailable`, and `SSHFailure`. Their exact serialized names/exit codes are application choices, not protocol values.

## 16. Security requirements

**TLS and origin binding.** Validate deployment certificates and hostnames. Store tokens against a normalized trusted deployment identity. Do not forward `Coder-Session-Token` to an arbitrary redirect target, user-specified relay, or unrelated workspace application origin. A private CA should be explicitly configured, not replaced with blanket certificate verification bypass.

**Relay headers.** Coder can propagate explicitly configured HTTP headers into DERP connections. Treat custom proxy headers as credentials with their own approved destination scope. Do not automatically copy the user's Coder token into every DERP node from a map. Audit proxy and relay transport configuration together. [S06, S14, S24]

**Credential isolation.** Separate token, user, deployment, workspace, and connection generations. Do not share one reusable tailnet across unrelated users simply because they selected the same agent. Concurrent connections under one identity can share infrastructure only with correct ownership/reference-counting and explicit authorization rules.

**No public unauthenticated raw listener.** The raw agent SSH endpoint accepts SSH without an additional user authentication challenge. A public forwarder would expose the authenticated Coder session's workspace access. Even a loopback listener can be accessible to other local users; stdin/stdout pipes are preferable for the initial adapter. [S17]

**Secret-free output.** Redact `Coder-Session-Token`, token-creation responses, cookies, resume-token query values, private keys, proxy authentication headers, and terminal contents. Logs of a URL containing a resume token are a credential leak even if other headers are redacted.

**No hidden lifecycle mutation.** Do not start, reactivate, update, delete, or extend a workspace outside the user's selected connection policy. Do not resolve a parameter mismatch by fabricating answers.

**Bounded parsing and memory.** Apply protocol frame/message limits, bounded queues, request deadlines, and cancellation. An SSH file transfer must be streamed instead of buffered in full. Close resources on every partial failure.

**Server restrictions remain authoritative.** Honor browser-only access, direct-path restrictions, file-transfer blocks, and forwarding blocks. Do not substitute a less-restricted endpoint to evade a restriction. [S09, S17]

## 17. Optional extensions and explicit exclusions

### 17.1 Authenticated SSH gateway

The core can later support a conventional jump-host frontend:

```text
remote SSH client
  → authenticated SSH connection to gateway
    → authorized direct-tcpip channel for a configured workspace alias
      → gateway's Coder transport core
        → raw agent SSH stream
```

The gateway MUST authenticate the incoming user, map them to the correct Coder identity/profile, authorize the requested workspace/agent, and keep a normal verified gateway host key. A requested host/port cannot become an unrestricted network dial or arbitrary Coder-agent selection. The final SSH connection can remain a byte stream inside the jump channel.

A Coder-token enrollment/renewal conversation belongs in a separate gateway control/session flow. It cannot be injected into a `direct-tcpip` stream that already belongs to the destination SSH protocol. After replacing credentials, new connections should use a fresh client generation. This is an extension architecture, not a specification of a fully implemented gateway in the MVP.

### 17.2 Other non-goals

The MVP does not require a public workspace SSH port, Tailscale SaaS enrollment, an OS-wide VPN, a browser terminal implementation, template provisioning, Coder server modifications, or possession of workspace-agent credentials.

A clean-room implementation in another language is a separate engineering scope. It must implement or bind the full coordination/packet/network/SSH layers described here and pass the same interoperability tests. Implementing only REST and a WebSocket library is not sufficient.

## 18. Acceptance and interoperability tests

Do not declare compatibility based solely on reaching an HTTP 101 response or seeing one terminal prompt. Run an end-to-end suite against a representative deployment and record its Coder version.

### 18.1 Required MVP tests

| Test | Expected result |
|---|---|
| Valid user token, one running agent | OpenSSH can execute a command through the raw adapter. |
| Invalid/expired user token | Actionable authentication-required error, no endless retry and no token on stdout. |
| Valid user but no SSH permission | Respect denial, including authorization-hidden 404 behavior. |
| Multiple agents without a selector | Explicit ambiguity error; no first-agent guessing. |
| Exact agent name and UUID selection | Correct current-build agent is reached. |
| Unknown or old-build agent UUID | Clear failure/re-resolution path; no accidental access to another workspace. |
| Stopped workspace, start disabled | No start POST occurs. |
| Stopped workspace, start explicitly enabled | One accepted start; build followed to the correct current agent. |
| Start POST response lost | State rechecked before retry; no duplicate blind mutation. |
| Dormant workspace or parameter mismatch | Explicit lifecycle/parameter action required; no silent changes. |
| Blocking and nonblocking startup scripts | `auto` waiting follows script policy. |
| Startup timeout/error | Bounded, informative failure or explicit diagnostic-login override. |
| Direct UDP path available | Session works; diagnostics can show direct connectivity when selected. |
| Direct UDP blocked | Session works through DERP. |
| Server disables direct connections | No user preference bypasses server policy. |
| DERP custom upgrade rejected, WS permitted | Compatible WebSocket relay fallback works. |
| Server forces DERP WebSockets | Initial relay setup uses the required transport. |
| Private CA/reverse proxy | Approved trust/auth works on REST, coordinator, and relay; no blanket TLS bypass. |
| Dynamic DERP map update | Connection manager applies updates without corrupting the SSH stream. |
| Coordinator connection reset | Appropriate control reconnect; no command replay. |
| Invalid/expired resume token | Retry without resume token, not a spurious login prompt. |
| Agent restart/workspace rebuild | Existing session ends appropriately; new connection resolves the right agent. |
| Network change or suspend/resume | Bounded recovery or clear reconnect error; no leaked sessions. |
| Interactive terminal resize | Terminal dimensions update correctly through the chosen SSH client. |
| Noninteractive binary stdout | Byte-exact output; no CRLF/text transformations or debug banners. |
| Remote command exit status/stderr | Preserved by the downstream/native SSH implementation. |
| Large output and transfers greater than 4 MiB | Complete streaming transfer; coordinator limits not misapplied to SSH data. |
| SFTP and TCP forwarding when permitted | Work through the same raw transport. |
| File transfer/forwarding denied by server | Denial surfaced; no alternate-endpoint bypass. |
| Stdin EOF with trailing remote output | Half-close permits output to drain; no truncation. |
| Cancellation, stdout failure, peer EOF | Both copy directions and network/controller resources terminate. |
| Concurrent distinct profiles/users | No credential or peer-connection cross-contamination. |
| Usage lifecycle | Heartbeat begins only for real use and stops on close. |
| Logging/security audit | No user tokens, resume tokens, private keys, or terminal contents in logs. |

### 18.2 Additional tests for a lower-level/non-Go port

| Test | Expected result |
|---|---|
| Protobuf UUID encoding | Exactly 16 UUID bytes, not a string. |
| Node key encoding | `0x6e 0x70` followed by 32 raw bytes, total 34. |
| Disco key encoding | Correct `discokey:`-prefixed hexadecimal text. |
| Virtual address fixture | UUID `00112233-4455-6677-8899-aabbccddeeff` maps to the address in section 9. |
| Arbitrary WebSocket fragmentation/coalescing | Yamux/DRPC decode correctly across message boundaries. |
| Concurrent coordinate and DERP-map streams | Neither monopolizes the other; unary refreshes still function. |
| DRPC server-stream request half-close | DERP-map stream remains readable after closing its request side. |
| All peer-update kinds | Correct handling, including handshake readiness and loss/removal. |
| DERP raw key versus protobuf key | Prefix is not incorrectly included in DERP packet destinations. |
| DERP ping/pong and server restart notices | Correct responses and bounded reconnect behavior. |
| Oversized/malformed frames | Rejected safely without unbounded allocation or process crash. |
| Data-plane packet interpretation | Packet payloads are handled by the WireGuard/magicsock path, not treated as raw SSH bytes. |

Use the matching official Coder CLI as a behavioral reference on the same deployment. When a test fails, isolate REST authorization, coordination, relay/direct reachability, virtual TCP, and SSH rather than treating all failures as “SSH authentication.”

## 19. Implementation milestones and handoff instructions

**Milestone 1: dependency and transport proof.** Establish the pinned Go module graph. With an explicitly supplied valid token and known agent UUID, obtain `AgentConn.SSH()` and use it as an OpenSSH raw transport. Test both direct and forced-relay modes before adding UI complexity.

**Milestone 2: safe discovery and startup.** Add deployment profiles, token validation, exact workspace/agent resolution, bounded readiness waiting, and explicitly enabled start behavior. Add structured errors and tests for multiple agents and stale builds.

**Milestone 3: production connection ownership.** Implement correct stream half-close/cancellation, usage reporting, credential-generation replacement, reconnect classification, TLS/proxy handling, and secret-safe diagnostics.

**Milestone 4: compatibility and packaging.** Run the acceptance matrix, document tested server/client/platform versions, verify licenses/dependency pins, and package the chosen adapter. Only then consider a native mobile binding or authenticated gateway frontend.

### Instructions suitable for a coding agent

Implement the client described in this document, starting with a Go transport core and an OpenSSH raw-stdio adapter. Do not invoke the Coder executable as the production transport. Use the pinned `codersdk`/`workspacesdk` implementation and required module replacements instead of reimplementing WireGuard/DERP as a first step.

First inspect the source manifest and confirm the deployed Coder version. Establish a buildable module graph before implementing command parsing. Keep authentication/profile storage, workspace resolution/readiness, network transport, and adapter I/O separate. Default to no workspace mutation; require explicit start/reactivation policy. All raw-stdio diagnostics go to stderr; token prompts occur only in the login/control flow.

Implement and test the actual behaviors, not mocked claims of compatibility. In particular, demonstrate a real command, correct exit/output behavior, relay-only connectivity, large streaming output, clean cancellation, and invalid-token versus invalid-resume-token handling. Record any untested platform or server-version combinations explicitly. Keep code changes scoped to the new client and do not alter unrelated workspace/template configuration.

## 20. Source manifest

The Coder links below use the full reference commit, not a moving branch. Dependency links use the fork revision resolved from that release's module file. Function names identify the relevant code even when line numbers change in another release. Documentation URLs are supplementary and were current at the research date; they may describe a newer documentation version than the pinned source.

### Coder release and implementation

**[S01] Release identity.** GitHub's `releases/latest` response identified `v2.36.4`; the annotated tag resolved to commit `10fd510ada0e3a7c222511dbd9916f83afd1acf0`. The release was published September 1, 2026.

`https://github.com/coder/coder/releases/tag/v2.36.4`

`https://api.github.com/repos/coder/coder/git/tags/d654e71ada42f78c4894a77e477ae85a5f007304`

**[S02] SDK HTTP client and credential configuration.** `New`, `SessionTokenHeader`, `SessionTokenProvider`, token setter deprecation.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/client.go`

**[S03] API key/token types and endpoints.** `CreateTokenRequest`, `CreateToken`, `CreateAPIKey`, `APIKeyByID`, `ExpireAPIKey`, `GetTokenConfig`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/apikey.go`

**[S04] Workspace discovery, builds, dormancy, autostart, and usage.** `Workspace`, `CreateWorkspaceBuild`, `WorkspaceByOwnerAndName`, `ResolveWorkspace`, `ResolveAutostart`, `PostWorkspaceUsageWithBody`, `UpdateWorkspaceUsageWithBodyContext`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspaces.go`

**[S05] Agent state and script schema.** `WorkspaceAgent`, `WorkspaceAgentStatus`, `WorkspaceAgentLifecycle`, `WorkspaceAgentScript.StartBlocksLogin`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspaceagents.go`

**[S06] Main connection orchestration.** `AgentConnectionInfo`, `DialAgent`, `RewriteDERPMap`, `AgentReconnectingPTY`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspacesdk/workspacesdk.go`

**[S07] Coordinator WebSocket dialer.** `NewWebsocketDialer`, protocol version selection, resume-token validation/retry, RPC stream setup.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspacesdk/dialer.go`

**[S08] Agent stream API and SSH policy.** `AgentConn`, `SSH`, `SSHOnPort`, `SSHClientOnPort`, `agentAddress`, `DialContext`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspacesdk/agentconn.go`

**[S09] Server coordination entry point.** `workspaceAgentConnection`, `workspaceAgentClientCoordinate`, `handleResumeToken`; SSH authorization and error responses. Relevant handler region starts around source line 1180.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/coderd/workspaceagents.go`

**[S10] Normative Tailnet protobuf schema.** Entire schema, especially `Node`, `CoordinateRequest`, `CoordinateResponse`, `DERPMap`, `RefreshResumeTokenResponse`, and `service Tailnet`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/proto/tailnet.proto`

**[S11] Yamux/DRPC client construction.** `NewDRPCClient`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/client.go`

**[S12] DRPC multiplexing and limits.** `MaxMessageSize`, `YamuxDefaultStreamWindowSize`, `DefaultDRPCOptions`, `MultiplexedConn`, `Invoke`, `NewStream`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/drpcsdk/transport.go`

**[S13] Server-side Tailnet RPC implementation.** `ServeClient`, `ServeConnV2`, `StreamDERPMaps`, `RefreshResumeToken`, `Coordinate`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/service.go`

**[S14] Userspace engine, ports, addressing, and peer application.** `NewConn`, `Options`, service-port constants, `ServicePrefix`, `AddrFromUUID`, `UpdatePeers`, `DialContextTCP`, `Rebind`.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/conn.go`

**[S15] Wire conversions.** `UUIDToByteSlice`, `NodeToProto`, `ProtoToNode`, DERP map conversion functions.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/convert.go`

**[S16] Reference CLI SSH orchestration.** Retry behavior, stdio separation, startup waiting, Coder Connect branch, usage reporting, raw-SSH and SSH-client paths.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/cli/ssh.go`

**[S17] Agent's built-in SSH server.** `NewServer`, `NoClientAuth`, session/SFTP/channel handlers, forwarding/file-transfer policy, configured execution environment.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/agent/agentssh/agentssh.go`

**[S18] Optional agent-readiness watch.** `ConnectionWatchEvent`, error codes, and authenticated WebSocket setup.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/codersdk/workspacesdk/workspaceagentconnwatch.go`

**[S19] Toolchain and dependency graph.** Go version, module requirements, fork replacements.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/go.mod`

**[S20] Build info and deployment SSH metadata.** `buildInfoHandler`, `sshConfig`; contrast with administrator-protected configuration endpoints.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/coderd/deployment.go`

**[S26] Generated DRPC methods.** Exact method strings, binary protobuf encoding, streaming request send/half-close behavior.

`https://github.com/coder/coder/blob/10fd510ada0e3a7c222511dbd9916f83afd1acf0/tailnet/proto/tailnet_drpc.pb.go`

### Exact networking-fork implementation

**[S21] Node key encodings.** `nodePublicBinaryPrefix`, `NodePublicRawLen`, `MarshalBinary`, `UnmarshalBinary`, raw32 accessors.

`https://github.com/coder/tailscale/blob/b7c5fc6e6399/types/key/node.go`

**[S22] Discovery key encodings.** `discoPublicHexPrefix`, `MarshalText`, `UnmarshalText`.

`https://github.com/coder/tailscale/blob/b7c5fc6e6399/types/key/disco.go`

**[S23] DERP wire framing.** Protocol version, login flow, frame header, packet bounds, frame types.

`https://github.com/coder/tailscale/blob/b7c5fc6e6399/derp/derp.go`

**[S24] DERP HTTP connection behavior.** URL construction, `connect`, `Upgrade: DERP`, fast start, fallback triggers, TLS and proxy headers.

`https://github.com/coder/tailscale/blob/b7c5fc6e6399/derp/derphttp/derphttp_client.go`

**[S25] DERP WebSocket wrapper.** `dialWebsocket`, `derp` subprotocol, binary stream adaptation.

`https://github.com/coder/tailscale/blob/b7c5fc6e6399/derp/derphttp/websocket.go`

### Supplementary official documentation

**[D01] Coder sessions and tokens.** Browser CLI authentication, session-expiry behavior, token lifetime/scopes.

`https://coder.com/docs/admin/users/sessions-tokens`

**[D02] Coder networking.** Network prerequisites, direct/relay architecture, userspace connectivity.

`https://coder.com/docs/admin/networking`

**[D03] User API reference.** User identity and token API documentation.

`https://coder.com/docs/reference/api/users`

**[D04] Build API reference.** Current build representation and removed legacy resource endpoint.

`https://coder.com/docs/reference/api/builds`

**[D05] Workspace API reference.** Workspace response examples including latest-build resources and agents.

`https://coder.com/docs/reference/api/workspaces`

**[G01] Go Modules Reference.** Semantics and scope of replacement directives.

`https://go.dev/ref/mod#go-mod-file-replace`

---

**Bottom line:** Build a real SSH byte-stream transport backed by the compatible Coder workspace SDK. Keep REST identity/discovery, WebSocket coordination, DERP/WireGuard networking, and SSH session behavior separate. That is the shortest implementation path that preserves the actual protocol instead of approximating it with an unrelated terminal WebSocket.
