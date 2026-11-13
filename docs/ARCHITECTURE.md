# Architecture Design Document: NanoSec

**Version**: 6.0
**Date**: 2026-11-11
**Status**: Current

This document describes the system as it is built today. Where it disagrees with a
design document, the code wins; where it disagrees with a plan, this is the state the
plan has to start from.

---

## 1. System Overview

### 1.1 The shape of the system

A person talks to NanoSec through a chat channel — a browser tab, WeCom, Feishu, the
WeChat customer-service channel, or a CLI. The message goes through a **gateway** into
the **bus**, the user's own **agent container** claims it, runs a turn (LLM, tools,
files, memory) and streams the answer back the same way.

The stack is split into independent services so that each one can be changed, scaled
or restarted on its own. Three rules hold the split together:

1. **The bus carries messages.** It owns the inbound and outbound queues, the HTTP
   RPC / REST / SSE surface that every channel and every agent container dials, the
   WebSocket tunnel into each agent container (files, git, terminals), and the small
   amount of state that belongs to that role (runner registry, WeChat
   customer-service cursors). It is the one address that has to be reachable by
   everything else.

2. **Every collection has exactly one writer.** That is the whole point of the
   prefixes introduced in P1: `portal_` is written by the portal, `admin_` by the
   admin module, `provisioner_` by the provisioner, `auth_` by the auth service,
   `bus_`/`sys_` by the bus, `artifacts_` by the work library. A module that needs
   another module's data asks it over HTTP. A handful of read-only direct reads are
   deliberate and listed in §1.4.

3. **Modules do not import each other.** `nanoprotocol` is the only shared library,
   and it holds wire types only. Everything else crosses a process boundary.

### 1.2 Process model

| Module | Binary (image) | Responsibility | Holds a database connection |
|---|---|---|---|
| `nanobus` | `nanobus` | Message transport: HTTP RPC (`POST /api/v1/rpc`), REST, SSE; per-user inbound/outbound queues; agent tunnel (files, git, terminals); runner registry; WeChat KF cursors. It forwards the console's writes to the module that owns the collection instead of performing them. | **yes** — `bus_*`, `sys_*` (reads `provisioner_*` for the console) |
| `nanogateway` | `nanogateway` | Channel adapters (CLI, WeCom, Feishu, web chat, WeChat KF); identity resolution; one SSE subscription per channel for outbound delivery. | no |
| `nanoportal` | `nanoportal` (Go server + nginx + React) | The user console and the user-facing data: agents, agent groups, binding preferences, the conversation projection, the console's operational views (users, containers, overview, conversations, runtime, runners). nginx sends the catalogue/config/audit pages straight to the admin module and identity straight to nanoauth; the portal proxies only the file/git/terminal surface to the bus and provisioner. | **yes** — `portal_*` |
| `nanoagent` | `nanosec` (one container per user) | The user's runtime. Inside the container a **hypervisor** supervises one child process per agent; each child runs the ReAct loop, tools, skills, memory, cron and its own JSONL sessions. | no (files live in the container volume) |
| `nanoprovisioner` | `nanoprovisioner` | Consumes the provisioning queue; creates, restarts and disposes agent containers through docker / swarm / k8s; applies per-tier quotas. | **yes** — `provisioner_*` |
| `nanoauth` | `nanoauth` | Accounts, channel links, OAuth links, refresh tickets, git shortcuts, per-user secrets; login, RS256 tokens and JWKS; corporate-directory login. | **yes** — `auth_*` |
| `nanoadmin` | `nanoadmin` | The platform catalogue and configuration: config items, agent types and overrides, prompts, models/providers, capabilities (built-in tools, skills, MCP), permission keys, alert rules, the audit log. | **yes** — `admin_*` |
| `nanoworkspace` | `nanoworkspace` | The agent workspace surface: file listing, previews, uploads and the git panel. Stateless — it verifies the caller, asks the portal who owns the agent, and forwards through the container's tunnel. | no |
| `nanoartifacts` | `nanoartifacts` | The work library: spaces, nodes, artifacts, GridFS bodies, the MCP endpoint agents publish through, and its own front end. | **yes** — `artifacts_*` |
| `nanoui` | `nanoui-backend` | WeChat Mini Program BFF: login forward, account, subscriptions, preferences. | no (talks to nanoauth) |

The agent container is not part of the compose stack: the provisioner creates it, on
demand, one per user. That container runs the hypervisor, which in turn runs one
`nanosec agent --agent <id>` child per active agent record.

### 1.3 Communication

| From | To | Transport | Purpose |
|---|---|---|---|
| Browser | portal's nginx | HTTPS | Everything, one origin (see §3.4 for the path map) |
| Browser | `nanoauth` | HTTP | Login, registration, refresh and logout under `/api/v1/auth/*` (nginx rewrites to `/auth/v1/*`; `/api/auth/v1/*` still works) |
| portal nginx | `nanoportal` Go | HTTP | Console API (`/api/admin/v1/*`, `/api/user/v1/*`), `/internal/*`, `/healthz` |
| portal nginx | `nanogateway` | HTTP + WS | Web chat (`/ws/agent/*`) and its REST (`/api/v1/*`) |
| portal nginx | `nanobus` | WS | Dictation socket (`/ws/voice`) |
| portal nginx | `nanoartifacts` | HTTP | Work library under `/nanoartifacts/` |
| Gateway | Bus | HTTP RPC + REST + SSE | Resolve identity, post inbound, subscribe outbound (one SSE stream per channel); bridge the browser terminal socket |
| Gateway | Portal | HTTP | The user's agents, a session's metadata, the binding's default agent |
| Gateway | Admin | HTTP | Its own configuration (`gateway` component) |
| Agent (child) | Bus | HTTP RPC + REST | Poll inbound, post outbound and stream chunks, capabilities, agent snapshot, skill/ack RPCs |
| Agent (child) | Portal | HTTP | Save the session projection, list agents, report agent status |
| Agent (child) | Admin | HTTP | Configuration and catalogue reads (models, types, capabilities) |
| Agent (child) | LLM provider (or LiteLLM gateway) | HTTPS | Chat completions, streaming |
| Agent (child) | `nanoartifacts` | HTTP (MCP) | Publish and read work-library artifacts |
| Hypervisor | Bus | WS | Tunnel registration; the bus then proxies file/git/terminal requests to it |
| Provisioner | Bus | HTTP RPC + REST | Register the runner, report a container's status, report the owner's status |
| Provisioner | Docker / Swarm / K8s | API | Create, restart, dispose agent containers |
| Provisioner | Admin | HTTP | Its own configuration (`runner` component) |
| Portal | Bus | HTTP | Users, container reads, capability reads/writes it forwards, the terminal proxy |
| Browser (via nginx) | Workspace | HTTP | `/api/v1/workspace/files/*` and `/api/v1/workspace/git/*` (file panel, previews, git; the older `/api/user/v1/…` paths still answer) |
| Workspace | Portal | HTTP | Who owns this agent (`GET /internal/v1/agents/{id}`) |
| Workspace | Provisioner / Bus | HTTP | Forwards the file/git request through the container's tunnel (provisioner first, bus while containers still dial it) |
| Provisioner (replica A) | Provisioner (replica B) | HTTP | Relays a tunnel request to the replica holding the connection (`provisioner_tunnels.runner_url`) |
| Portal | Admin | HTTP | The console views it still serves need catalogue values (e.g. agent rows); reads ask for masked values |
| Portal | `nanoauth` | HTTP | JWKS for token validation (direct; the bus proxy is legacy) |
| Browser (via nginx) | Admin | HTTP | The console's configuration/catalogue/audit routes and the container lifecycle under `/api/v1/admin/*` (the older `/api/admin/v1/*` answers too); the service verifies the JWT and the Management/Audit/Operations roles itself, and masks secrets on reads |
| Admin | Provisioner | HTTP | Container restart/dispose/reprovision: a desired-state write on the queue's owner, which executes it in its poll loop (never through the container's tunnel) |
| Portal | Mongo | driver | Its own collections |
| Bus | Admin | HTTP | Config writes, audit reports, catalogue writes it receives from older clients |
| Bus | Portal | HTTP | Agent-status write and a deleted type's reference cleanup |
| Bus | Provisioner | HTTP | The console's container actions |
| Bus | `nanoauth` | HTTP | `/auth/v1/*` reverse proxy (kept for compatibility) |
| `nanoauth` | Admin | HTTP | Its configuration (the JWT keypair, the `ldap.*` settings, the first-account switch) and the audit trail (`POST /api/v1/internal/audit`) |
| `nanoadmin` | Bus | HTTP | Broadcast capability changes; ask the agent-data owner to clear a deleted type's references |
| `nanoartifacts` | `nanoauth` | HTTP | JWKS (direct; the bus no longer proxies identity) |

Two transports deserve a note:

- **RPC over HTTP.** `nanoprotocol.Client` no longer opens a WebSocket: `Send` posts
  the `Message` envelope to `/api/v1/rpc` and decodes the reply (204 means "no
  payload"). That is why a service is given a `ws://` URL and still works —
  `normalizeBaseURL` turns it into `http://`. WebSockets remain only where a stream
  of frames is the point: the agent tunnel, the terminal bridge, the dictation socket
  and the browser's chat socket.
- **Outbound is SSE, not polling.** Chunks and completions are written to
  `bus_stream_events`, keyed by conversation (`channel` + `chat_id`): a regular
  collection (not `capped` — capped is collection-wide, has no TTL and cannot be
  sharded), indexed `{channel:1, chat_id:1, _id:1}` with a 600-second TTL on `at`
  and a per-conversation trim to the newest 1000 events. A subscriber asks
  `GET /api/v1/outbound/stream?channel=&chat_id=` and reconnects with
  `Last-Event-ID` (the event's ObjectId hex). Replay is one read of the log; live
  delivery comes from the replica's **tailer** (one change stream plus a 2-second
  safety scan per replica), which fans what it sees out to that replica's
  subscribers. Database reads therefore scale with replicas, not with open
  streams: fifty connected conversations cost the same query rate as two. A
  subscriber that falls behind is told (`lag`) and catches up from the log rather
  than being fed a hole. A cursor older than the retained window — or one this
  process cannot parse — gets an explicit `reset` event instead of a silent gap.
- **Conversation subscriptions.** The gateway opens one SSE per
  `(channel, chat_id)` when it dispatches an inbound message. It reads
  `GET /api/v1/outbound/cursor` *before* posting the message, so the subscription
  starts where the conversation ends: the coming reply is not missed and the
  previous turn is not replayed. A subscription closes on `complete`, after ten
  idle minutes, or by evicting the oldest beyond 200 per adapter; one that cannot
  connect within 30 seconds releases its key so the reply is not lost.
- **Legacy channel subscription.** `GET /api/v1/outbound/stream?channel=` without
  `chat_id` still reads the in-memory per-channel ring (1000 events). It remains
  as the delivery path for conversations with no dedicated subscription (a cron
  turn) and skips conversations that have one, so nothing is delivered twice.
- **`poll_outbound`** remains in the protocol and the bus for older clients; the
  gateway no longer calls it.
- **Writes are coalesced and batched.** Chunks of the same message and kind are
  merged inside a 200 ms window into one document (content concatenated in order,
  `seq` keeps the last value); merged rows from every conversation are then
  written in one `insertMany` per 20 ms window. A `complete` flushes the
  conversation's pending chunk first and waits for both writes before answering,
  so a stored answer never follows its own completion and the gateway never closes
  a subscription on an event the log has not got. A 5,000-event burst becomes
  about 140 documents.
- **Metrics**: `GET /metrics` on the bus (internal network, anonymous — it is not
  under `/api/v1`, so the internal-token guard excludes it by name) exposes
  `bus_stream_events_written_total{type}`, `bus_stream_subscribers` and
  `bus_stream_write_seconds`.

### 1.4 Data ownership

One MongoDB database (`NANOSEC_BUS_DATABASE_URI`), one prefix per writer:

| Prefix | Writer | Examples |
|---|---|---|
| `portal_` | portal | `portal_agents`, `portal_agent_groups`, `portal_binding_preferences`, `portal_sessions` |
| `admin_` | admin | `admin_config`, `admin_agent_types`, `admin_agent_type_overrides`, `admin_models`, `admin_model_providers`, `admin_prompts`, `admin_permission_keys`, `admin_builtin_tools`, `admin_skills`, `admin_mcp_servers`, `admin_alert_rules`, `admin_audit_log` |
| `provisioner_` | provisioner | `provisioner_container_requests`, `provisioner_runners` |
| `auth_` | nanoauth | `auth_users`, `auth_oauth_providers`, `auth_refresh_tokens`, `auth_git_shortcuts`, `auth_secrets` |
| `bus_` | bus | `bus_inbound_queue`, `bus_outbound_queue`, `bus_wechatkf_sync_state`, `bus_stream_events`, `bus_platform_events`, `bus_voice_sessions` |
| `artifacts`, `artifacts_` | nanoartifacts | `artifacts`, `artifacts_versions`, `artifacts_spaces`, `artifacts_nodes`, `artifacts_uploads`, `artifacts_fs.files` / `artifacts_fs.chunks` |
| `sys_` | infrastructure, written by the module that owns the record | `sys_migrations` (one row per module manifest), `sys_counters` (sequences), `sys_flags` (one-shot flags) |

`sys_migrations` is one collection for the whole platform: each record's `_id` is
`<service>:<manifest>`, so two services can both have a `0001_*.json` without
confusing each other.

Some collections are created on first write, so they are legitimately absent on a
fresh installation — `portal_binding_preferences` (no channel has been pinned to an
agent), `bus_wechatkf_sync_state` (the channel is off), `sys_flags` (nothing claimed
yet). Absence means "nothing set", not "missing feature".

Three read-only cross-module reads are deliberate, because each replaces a per-request
HTTP fan-out with one query, and none of them writes:

- `nanoadmin` reads `auth_users` / `portal_agents` / `portal_agent_groups` to render
  names in the audit log.
- `nanoportal` reads `auth_users` to show a person's name in the session log.
- `nanoprovisioner` reads `auth_users` for the owner's tier (the quota) and display
  name (the container name).
- `nanobus` reads `provisioner_container_requests` and `provisioner_runners` for the
  console's container and fleet views. Both are the provisioner's collections; the bus
  only reads them, and every write is forwarded.

---

## 2. Module Structure

### 2.1 Repository layout

The super-repo contains the Go workspace, the compose file, the deployment manifests
and the docs. Most modules are git submodules; two are plain directories in the
super-repo.

```
nanosec/                              # super-repo
├── go.work                           # workspace: 9 modules + the go-workwx replace
├── docker-compose.yml                # one-host stack (see §8)
├── .gitmodules
├── deploy/{swarm,k8s}/               # alternative deployment targets
├── docs/                             # this document and the design docs
├── plans/                            # implementation plans and reports
├── scripts/                          # bump-protocol.sh, install-hooks.sh, ...
│
├── nanoprotocol/                     # shared wire types + client (submodule, semver tags)
├── nanobus/                          # message bus (submodule) + migrations-mongo/
├── nanogateway/                      # channel gateway (submodule) + vendored go-workwx
├── nanoagent/                        # agent runtime (submodule); the binary is `nanosec`
│   └── internal/{agent,provider,session,tool,skill,cron,workspace,hypervisor,mcp,...}
├── nanoprovisioner/                  # container provisioning (submodule)
├── nanoauth/                         # identity service (submodule) + migrations/
├── nanoadmin/                        # platform catalogue + config (submodule) + migrations/
├── nanoportal/                       # console (submodule): server/ (Go) + web/ (React)
├── nanoartifacts/                    # work library (plain directory: Go + own web front end)
└── nanoui/                           # WeChat Mini Program + Go BFF (submodule)
```

`go.work` includes nine modules: `nanoportal`, `nanobus`, `nanogateway`,
`nanoprotocol`, `nanoprovisioner`, `nanoagent`, `nanoauth`, `nanoartifacts`,
`nanoadmin`. `nanoui` is built on its own (`GOWORK=off`).

### 2.2 Dependency rules

- Every service may import `nanoprotocol`. Nothing else is shared.
- `nanobus`, `nanogateway`, `nanoagent`, `nanoprovisioner`, `nanoauth`,
  `nanoadmin`, `nanoportal` do not import each other.
- `nanoprotocol` holds wire types and an HTTP client only — standard library, no
  third-party imports. (`go.mod` still lists `gorilla/websocket`, which nothing
  imports any more; it is a leftover to tidy, not a licence to use it.) New shared
  wire types go there; service logic stays in the service.
- A protocol change is tagged (`vX.Y.Z`) and every consumer's `go.mod` is bumped by
  `scripts/bump-protocol.sh`; the bus, gateway, agent and provisioner are the
  consumers the script updates.
- Each module owns its migration manifests and applies them at startup
  (`sys_migrations` gets a `<service>:` prefixed record).

---

## 3. Core Components

### 3.1 Wire protocol (`nanoprotocol`)

The protocol is one envelope plus a set of typed payloads. It is the only code two
services share.

```go
type Message struct {
    Type    string          `json:"type"`
    Payload json.RawMessage `json:"payload,omitempty"`
    Error   string          `json:"error,omitempty"`
}
```

`Client` is an HTTP client for the bus. It normalises `ws://`/`wss://` URLs to
`http://`/`https://`, sends `POST /api/v1/rpc`, and returns the decoded reply (a 204
means the request had no payload). The default timeout is 60s.

The message types the bus dispatches today:

| Type(s) | Direction | Purpose |
|---|---|---|
| `resolve_user` | gateway → bus | platform identity → user, binding, new-user flag |
| `post_inbound`, `poll_inbound` | gateway / agent ↔ bus | enqueue an inbound message; claim the next one |
| `post_outbound`, `poll_outbound` | agent / gateway ↔ bus | enqueue a non-streaming reply (`poll_outbound` is legacy; the gateway uses SSE) |
| `list_containers` | console → bus | read the console's container list |
| `register_runner` | provisioner → bus | register or refresh a runner |
| `validate_token` | gateway → bus | the bus asks nanoauth whether the browser's token is valid |
| `update_user_status` | provisioner → bus | mark the owner active/idle |
| `get_user_info` | service → bus | owner status/tier read |
| `get_wechatkf_sync_state`, `update_wechatkf_cursor`, `update_wechatkf_callback_token` | gateway ↔ bus | customer-service channel cursors |
| `get_capabilities` | agent → bus | the agent's resolved capabilities (catalogues live in admin) |
| `get_agent_snapshot` | agent → bus | one call that returns the agent row plus the catalogue it needs |
| `builtin_tools_sync` | agent → bus | declare the built-in tools the binary knows (forwarded to admin) |
| `skill_save`, `skill_delete`, `skill_ack` | portal/agent → bus | skill writes and acknowledgements (forwarded to admin) |
| `list_agent_types`, `set_agent_permission` | agent/portal → bus | type catalogue read; per-mode permission write (forwarded to admin) |

Everything else is plain REST. The protocol also carries the SSE helper
(`subscribeSSE`) used for outbound chunks and for change notifications.

### 3.2 Bus service (`nanobus`)

**Purpose**: move messages between channels and agents, and be the single address the
rest of the stack dials.

Surface:

- `POST /api/v1/rpc` — the message dispatch above.
- `POST /api/v1/inbound`, `/api/v1/outbound`, `/api/v1/outbound/chunk`,
  `/api/v1/outbound/complete` — the REST spelling of the same operations.
- `GET /api/v1/outbound/cursor?channel=&chat_id=` — the conversation's newest
  event id; a gateway subscribes from here before dispatching a message.
- `GET /api/v1/outbound/stream?channel=&chat_id=` — per-conversation SSE with
  `Last-Event-ID` replay from `bus_stream_events` (600 s TTL, 1000 events per
  conversation, `reset` for an expired cursor), then the replica's tailer. Without
  `chat_id` the route still serves the legacy per-channel ring. Chunks and completions live here; only a
  non-streaming outbound message is also written to the queue.
- `GET /api/v1/events/stream` — change notifications (config, models, agent
  records, capabilities). They are written to `bus_platform_events` (24-hour TTL,
  newest 10,000 kept) and read back with `Last-Event-ID`, then followed live from
  the replica's tailer, so a subscriber on any replica sees every change; a fresh
  subscriber starts at the current end rather than replaying the retained window.
- `GET /ws/hypervisor` — the hypervisor tunnel, kept only for containers whose
  image still dials the bus. Tunnels terminate at the provisioner now
  (`GET /ws/hypervisor` there, registry in `provisioner_tunnels`); when the bus
  holds no connection for a name it relays the request to the provisioner, which
  is what lets a file or git call reach a container regardless of which module
  it connected to. The bus proxies `/api/v1/files/{agentID}/*`,
  `/api/v1/git/{agentID}/*` and the terminal bridge through that tunnel.
- `GET /ws/terminal` — the browser terminal bridge (the gateway pumps frames here).
  The gateway dials the provisioner's bridge first and falls back to this one for
  containers that still connect to the bus.
- `GET /ws/voice?session=` — the dictation socket (§4.5).
- `/auth/v1/*` (and `/api/auth/v1/*`) — reverse proxy to nanoauth. Kept for older
  clients; the console, the work library and nginx all reach nanoauth directly now.
- The console's read surface: users and user accounts, containers, runners, queues,
  activity, overview counts, WeChat KF counts.

Writes the bus receives but does not own are forwarded and the owner's answer is
returned unchanged: configuration and audit to admin, accounts and links to nanoauth,
catalogues (agent types, models, prompts, capabilities) to admin, an agent's runtime
status and a deleted type's reference cleanup to portal, the console's container
actions and runner registration to provisioner.

Queues:

- `bus_inbound_queue` / `bus_outbound_queue`. A claim is one atomic
  `findOneAndUpdate` that flips `status` from `pending` to `claimed`, so two pollers
  cannot take the same message.
- The agent polls inbound every 500 ms. The inbound row is kept (claimed, not
  deleted), which makes the queue an append-only log of what was delivered.

Guards: every protected endpoint requires `NANOSEC_BUS_INTERNAL_TOKEN`
(constant-time compare, `Authorization: Bearer` or `?token=` for a WebSocket
handshake). Two routes are exempt and authenticate themselves: `/ws/voice` (a
single-use id minted by the portal) and the directory-login subtree (the caller's JWT,
re-verified by nanoauth). An unconfigured token refuses the protected routes rather
than opening them. Per-IP rate limiting is the outermost middleware.

### 3.3 Gateway service (`nanogateway`)

**Purpose**: adapt chat platforms to the bus, and resolve who is talking.

| Adapter | Channel | Transport in | Transport out |
|---|---|---|---|
| CLI | `cli` | stdin | stdout |
| WeCom | `wecom` | HTTP callback (vendored `go-workwx`) | WeCom API |
| Feishu | `feishu` | WebSocket (`oapi-sdk-go`) | Feishu API |
| Web chat | `web` | WebSocket + REST | WebSocket (chunks and completions) |
| WeChat KF | `wechatkf` | polling + callback | WeChat API |

Inbound: resolve the sender (`resolve_user`; the web channel already has a verified
user), pick the agent — an explicit `agent_id`, else the binding's default agent from
the portal, else the user's first agent — then `post_inbound`.

Outbound: one SSE subscription per channel. A streaming reply is accumulated per
`message_id` by a chunk aggregator; `complete` flushes the assembled message. Media
and errors are handled in the same loop, and a failed send becomes an error notice to
the user rather than a silent drop.

The web channel listens on `:8080` (published as the portal's `/ws/agent/*` and
`/api/v1/*` upstream). Its browser sockets are keyed by chat: one chat can have
several open tabs and every one of them receives the event (a failing write drops only
that connection). It validates the browser's token through the bus's `validate_token`
RPC, which is nanoauth's answer.

### 3.4 Portal service (`nanoportal`)

**Purpose**: the console — and the owner of the user-facing data.

The Go server does four things:

1. **Authentication surface.** `/api/user/v1/auth/{login,register,refresh,logout}`
   proxy to nanoauth (through the bus), so the browser has one origin. The portal
   validates the resulting JWT against the JWKS endpoint and enforces roles/ownership.
2. **User-facing data.** Agents, agent groups, binding preferences and the
   conversation projection are served locally from `portal_*` (list, create, update,
   delete, restart, re-provision, arrange, attention, sessions with ETag and history
   paging).
3. **Proxy.** Everything the console does not own is forwarded: catalogues and
   configuration and audit to admin, accounts/links/shortcuts/secrets to nanoauth,
   containers/runners/capabilities and the file/git/terminal surface to the bus.
4. **Internal API.** `/internal/v1/*` is a second surface, addressed by the other
   services with the shared token (never by a browser): agent status, session
   projection writes and reads, binding agent, agent reference cleanup. It refuses
   requests when the token is unconfigured.

nginx (in the portal image) is the single origin for the browser:

Every module answers under `/api/v1/<module>/…`, so the owner of a path is
readable from the path itself. The older prefixes stay as aliases until no
caller uses them; the front end already uses the target-state ones.

| Path | Upstream |
|---|---|
| `/api/v1/workspace/files/*`, `/api/v1/workspace/git/*` | `nanoworkspace` |
| `/api/v1/admin/*` | `nanoadmin` (configuration, catalogues, prompts, permission keys, alert rules, audit, and the container lifecycle — it verifies the JWT itself) |
| `/api/v1/auth/*` | `nanoauth`, rewritten to `/auth/v1/*` |
| `/api/user/v1/files/*`, `/api/user/v1/git/*` | `nanoworkspace` (alias) |
| `/api/user/v1/*`, `/internal/*`, `/healthz` | portal Go |
| `/api/admin/v1/users*`, `/containers/*`, `/overview`, `/components*`, `/conversations*`, `/runtime`, `/runners*` | portal Go (the console views whose data it holds — except `/containers/*`, which is the admin module's control plane) |
| `/api/admin/v1/directory/*` | `nanoauth`, rewritten to `/auth/v1/directory/*` (alias) |
| `/api/admin/v1/*` (everything else) | `nanoadmin` (alias of `/api/v1/admin/*`) |
| `/api/auth/v1/*` | `nanoauth`, rewritten to `/auth/v1/*` (alias) |
| `/api/v1/*` | gateway (the web channel's REST) |
| `/ws/agent/*` | gateway (chat and terminal sockets) |
| `/ws/voice` | bus (dictation) |
| `/nanoartifacts/*` | the work library |
| `/fonts/*`, `/manifest.webmanifest`, `/` | the React build |

The front end is React 19 + Vite. The workbench (chat, files, git, terminal,
configuration) is a panel host: every panel stays mounted and is moved between docks,
so a panel must never assume it is visible when it mounts — a hidden panel measures
zero height (see the `isLaidOut` helper and the auto-grow textarea, which re-measure
through a `ResizeObserver`).

Module front ends are **remote plugins**: the shell imports no module code, it reads
`src/portal/plugins.json` (which plugin to load, and which panels the shell itself
ships), then fetches each plugin's manifest and loads components with Module
Federation at runtime. A plugin contributes two things, both from the same manifest:

- **panels** — workbench panels it owns (the work library's tree and document);
- **pages** — routes it takes over. The shell keeps its own page as the fallback, so
  a plugin can be added or removed with a manifest change rather than a rebuild.

Every plugin is served from one namespace, `/plugins/<id>/` (`nginx` maps each id to
the service that builds it), which is what lets one module's image update its front
end without touching the shell.

Two plugins exist today:

- `nanoartifacts` (`/plugins/artifacts/`) contributes the two library panels and the
  `/artifacts` page; the shell's framed page remains as the rollback path.
- `auth` (`/plugins/auth/`, served by `nanoauth` itself) contributes the account list
  at `/admin/users`, the account detail at `/admin/users/:id` and the user's own
  account at `/me`; the shell's own pages remain as the fallback. A contribution may
  be a route pattern — the shell matches it against the current location, and the
  page reads the parameters from `ctx.params`.
- `admin` (`/plugins/admin/`, served by `nanoadmin`) contributes the runtime snapshot
  at `/admin/runtime`, same fallback rule.

A page cannot import the shell's source, so its context carries the shell's
component kit (`ctx.ui`), the strings (`ctx.t`), a token-carrying data client
(`ctx.api`), the shell's notifications (`ctx.toast`), the shell **features** a page
may invoke (`ctx.features`) — today the agent editor: the agent rows are the
portal's, so a page asks the shell to open it by id instead of rebuilding it — and,
for the one component too large to freeze as a prop list, the component itself:
`ctx.ui.FilePanel` is a reference the shell hands over, so the workspace feature can
move to its own module later without touching the pages that embed it. `ctx.params`
carries the route parameters and `ctx.setCrumb` publishes the breadcrumb name.

Two rules for anyone writing a page or a host: a component must be defined at module
scope (a component created during render is a new type every render, so React
remounts its subtree — that is an update loop, which is what a nested section
wrapper caused once), and a context value handed to pages must be memoized or
reduced to stable members (a setter whose identity changed every render re-ran every
page's "publish my name" effect forever). That
keeps one implementation of every control and one compiled stylesheet while the page
lives in its own application; the contract lists the props and calls a page may rely
on.

### 3.5 Agent service (`nanoagent`, binary `nanosec`)

**Purpose**: run the user's agents. One container per user, one child process per
agent.

The container starts `nanosec hypervisor --user <id> --bus-url <bus>`. The hypervisor
is PID 1 and does three things:

1. **Supervises agents.** It reads the user's agent rows from the portal and spawns
   `nanosec agent --user <id> --agent <agentID> --bus-url <bus> --ready-fd <n>` per
   active agent. A child reports readiness through the pipe; a crash is retried with
   backoff; a deleted agent is never resurrected. Agent status (`spawning`, `ready`,
   `failed`) is written back through the portal.
2. **Serves the container's local API.** Files, git and terminal endpoints on `:9090`
   (`/api/v1/files/{agentID}/*`, `/api/v1/git/{agentID}/*`, `/api/v1/terminals/*`).
3. **Registers a tunnel** with the bus, which is how the console reaches those
   endpoints: the bus proxies the request over the tunnel, so no agent port is ever
   published.

Each child owns its agent's state under the container's data root:

- a **home** directory (`agents/<name>`) holding `AGENT.md`, `SOUL.md`, `USER.md`,
  `TOOLS.md`, `MEMORY.md`, the day's notes, skills and the workspace;
- **sessions** as JSONL files, one per session id (`web_<chat>_v<N>.jsonl`), which
  are the authoritative copy;
- a **projection** of each session into the portal, so the console can list, page and
  archive conversations without opening the container.

A turn looks like this: claim an inbound message → load the session → build the
request (frozen system head, history, the mode note, the language note, and any
"changed file" notes at the tail) → call the model with the tool definitions → execute
tool calls and loop (bounded by `agent.maxIterations`) → stream `chunk` events and one
`complete` → save the session. A snapshot is written every 2 s *during* the turn, so a
crash loses at most a couple of seconds of text.

Long conversations are compacted: when the estimated prompt size crosses
`summarize_token_percent` of the model's window, the agent summarises the oldest turns,
writes the summary into the session head and records a floor so the next request starts
after the summarised range. The request layout is built for prefix caching — the head
is stable within a session segment, and anything volatile is appended at the tail.

Tools (enabled per agent type, and per agent in the console):

| Group | Tools |
|---|---|
| Shell & files | `bash`, `readonly_bash`, `read`, `write`, `edit`, `append_note`, `glob`, `grep` |
| Web | `webfetch`, `web_search` |
| Planning | `todowrite`, `plan_write`, `plan_execute`, `question` |
| Delegation | `task`, `readonly_task`, `parallel_execution` |
| Skills | `load_skill`, `manage_skill` |
| Scheduling | `cron` |
| Media | `download_media`, `upload_media` |
| MCP | the tools of every MCP server enabled for the agent (the work library's publish/read tools come this way) |

Delegated agents are restricted by the caller's permission plane: a read-only parent
can only delegate to read-only subagents, and the permission rules travel with the
task. Besides the conversational loop, the runtime runs small utility calls with their
own prompts (summarise, title, memory flush), so a compaction can move durable facts
into the agent's memory file before the summary replaces the turns.

Scheduled tasks live in `agent/cron.json`. Firing a task posts an inbound message
with `source: cron`, so it starts a real turn in a conversation of its own; because no
user is present, the `question` tool refuses instead of blocking, and the run's mode
comes from the task, then the agent, then the platform default (`build`).

### 3.6 Provisioning service (`nanoprovisioner`)

**Purpose**: turn "this user needs a container" into a running container, and keep it
that way.

It also owns the runner registry (`provisioner_runners`): at startup it registers
itself, every minute it reports a heartbeat and sweeps rows that stopped reporting
(two minutes), and the console prunes dead rows through the bus. The heartbeat lives
here now precisely because the poll loop does — the bus stopped seeing the runner on
every poll, so a heartbeat kept at the bus would have gone stale.

The queue is its own (`provisioner_container_requests`); it polls every
`runner.pollInterval` seconds (5 s by default) and dispatches each pending row on its
own goroutine, so one slow container does not hold up the others. For each request it
resolves the backend and the quota, then calls the backend:

| Backend (`runner.backend`) | Provision unit | Notes |
|---|---|---|
| `docker` (default) | container | Docker Engine over the socket |
| `swarm` | single-replica service | per-user service with limits |
| `k8s` | Deployment | in-cluster client; RBAC in `nanoprovisioner/deploy/k8s` |

Quotas come from the owner's tier (`auth_users.tier`, read-only):
`free` 512 MB / 1 CPU, `pro` 2048 MB / 2 CPU, `ultra` 4096 MB / 4 CPU.

The container name is `<runner.namePrefix><userID>` with the binding id appended when
there is one (`devnanosec-nanosec-agent-…` in the reference deployment), and the data
volume is per user. The container receives `NANOSEC_BUS_INTERNAL_TOKEN`,
`NANOSEC_ADMIN_URL`, `TZ`, and the hypervisor command; it does not receive the database
URI.

Lifecycle: `pending → creating → running`, with `failed`, `restarting`,
`suspended`, `disposing → disposed` around it. The console's actions (create, restart,
re-provision, dispose) arrive over the internal API, forwarded by the bus.

### 3.7 Auth service (`nanoauth`)

**Purpose**: identity. Accounts, their channel and OAuth links, refresh tickets, git
shortcuts and per-user secrets are this service's collections.

Public endpoints:

- `POST /auth/v1/register`, `/auth/v1/token`, `/auth/v1/token/refresh`,
  `/auth/v1/logout`
- `GET /auth/v1/userinfo`
- `POST /auth/v1/oauth/wechat` (Mini Program login)
- `GET /auth/v1/.well-known/jwks`

Tokens are RS256. The keypair is generated on first boot and stored in the platform
configuration (`admin_config`, component `auth`, keys `jwtPrivateKey`/`jwtPublicKey`),
so no key files are mounted and every replica signs with the same key. Consumers
validate through the JWKS endpoint (the bus proxies it for the work library).

`POST /auth/v1/token` accepts either a platform password or a corporate-directory
password. With `ldap.enabled=true` (component `auth`, prefix `ldap.*`) the identifier
is the corporate email, the password is verified against the directory entry, and a
first successful login either provisions an account or links the directory identity to
the existing account with the same email. Which accounts use the directory is recorded
in `auth_oauth_providers` (`provider='ldap'`) and shown in the console as
`auth_source`.

Refresh tickets are single-use: presenting one consumes it and issues a pair. That is
why several browser tabs must coordinate (the portal serialises refreshes with a
`navigator.locks` lock and re-reads the stored token after acquiring it).

The first account created on a fresh installation is promoted to administrator once,
atomically, when `auth.firstUserIsAdmin` is on. The rule runs here, next to the
collection it changes: registration writes the account in this service, so a sign-up
does not need the bus to be up (it used to call a create endpoint the bus forwarded
straight back to the internal surface).

The `/internal/v1/*` surface (shared token) is how the bus and the portal reach
accounts, links, shortcuts and per-user secrets. It refuses requests when
the token is unconfigured, and answers "unavailable" rather than an empty list when the
database is missing.

### 3.8 Admin service (`nanoadmin`)

**Purpose**: the platform's catalogue and configuration, and the audit log.

- **Configuration**: `admin_config` is the single key-value store, one row per
  `(component, key)`, seeded by `nanoadmin config seed` and edited in the console.
  Every other module reads its own component over HTTP.
- **Catalogue**: agent types and their overrides, the session head prompts and the
  per-type prompts, models and providers, permission keys, built-in tool state,
  skills, MCP servers, alert rules.
- **Audit**: `admin_audit_log` is written only here, through `POST /api/v1/internal/audit`
  (the bus's handlers and the portal report; failures never fail the user's action) or
  by its own console actions. Reads resolve ids to display names with one query.
- **Internal endpoints** for the writes the bus still receives from older clients:
  skill save/delete/ack, built-in tool sync, per-agent capability and permission
  patches, `clear-refs` notifications.

The catalogue is deliberately separate from the agent rows: a type or a model is
platform data, an agent is a user's data.

### 3.9 Work library (`nanoartifacts`)

**Purpose**: a place for agents to publish self-contained HTML documents (a report, a
dashboard, a small app) and for people to browse them.

- Data: spaces → nodes (a tree) → artifacts → versions; ACLs at the space and artifact
  level; bodies in GridFS, keyed by `sha256` so identical bytes are stored once and
  counted once against the user's quota.
- HTTP API under `/api/v1/*`, mounted by the portal's nginx at `/nanoartifacts/`;
  identity is nanoauth's JWT (validated against the JWKS endpoint through the bus), and
  a scoped preview-session cookie carries the iframe.
- MCP endpoint for agents (`POST /mcp`, plus `/mcp/blobs` for out-of-band uploads).
  `artifact_publish` takes either inline HTML or an `html_file` path in the agent's
  workspace; the latter uploads the bytes first and publishes by handle, so the model
  never has to repeat a large document as a tool argument.
- Its own front end (a separate build) is loaded by the console either directly at
  `/nanoartifacts/` or as a module-federation remote panel.

### 3.10 Speech recognition (external)

**Purpose**: dictation without the platform running a recogniser.

The recognition runtime is no longer part of the stack. The bus still owns the
relay (the provider key never reaches the browser) and speaks the OpenAI realtime
protocol to any configured provider; that provider is an external service now —
LiteLLM's `/v1/realtime`, or anything with the same contract. There is no local
engine and no `realtime.engine` switch: whichever provider the realtime tier points
at is what serves it.

### 3.11 Mini Program (`nanoui`)

The WeChat Mini Program and its Go BFF: login through nanoauth's WeChat endpoint,
account and subscription pages, and the preferences the Mini Program shows. It is not
part of the compose stack: it is deployed separately and talks to nanoauth over HTTP.

---

## 4. Data Flows

### 4.1 One message, end to end

```
User → wecom / feishu / web / kf / cli
  │
  ▼
Gateway
  1. resolve the sender (resolve_user → bus → nanoauth)
  2. choose the agent (explicit id → binding default from the portal → first agent)
  3. POST /api/v1/inbound
  │
  ▼
Bus
  4. insert into bus_inbound_queue (pending)
  │
  ▼
Agent child (poll every 500 ms)
  5. claim the oldest pending row (pending → claimed)
  6. load the session, build the request, call the model
  7. execute tools, loop; stream chunks as they are produced
  8. save the session (JSONL) and its projection (portal, every 2 s and at the end)
  │  POST /api/v1/outbound/chunk, /api/v1/outbound/complete
  ▼
Bus
  9. append to `bus_stream_events` (channel + chat_id), wake the conversation's
     subscribers, and keep feeding the legacy channel ring (§1.3)
 10. a non-streaming outbound is also written to bus_outbound_queue
  │
  ▼
Gateway (SSE subscription; per channel today, per conversation next)
 11. aggregate chunks per message_id, deliver to the platform
 12. on complete, deliver the assembled message (or the error notice)
```

The web channel is the same path with a browser on both ends: the portal's nginx
proxies `/ws/agent/*` and `/api/v1/*` to the gateway, the gateway validates the token
through the bus, and every open tab on that chat receives the events.

### 4.2 First message from an unknown identity

```
Gateway → bus: resolve_user(channel, sender_id)
  Bus
   1. ask nanoauth to resolve the identity
        - a channel link exists → {user_id, binding_id, is_new: false}
        - none → insert one account (status=pending, tier=free) with the channel
          link and its binding id → {…, is_new: true}
   2. on is_new: ask the portal to ensure the account has an agent; the account
      arrives without one, and a container with no agent answers nothing
   3. enqueue a container request naming that agent (provisioner)
   4. answer {user_id, binding_id, is_new}
  │
  ▼
Provisioner picks the request up and creates the container (§4.4)
  │
  ▼
The gateway picks the agent for the message: explicit id → the binding's default
agent (portal) → the owner's first active agent (portal)
```

The default agent is created by the portal's internal ensure endpoint: it is
idempotent (an account that already has an agent keeps it), named `My Agent`, uses the
`build` type, and its id is `<userID>-default`. A deleted row at that id is revived,
because "make sure this account has an agent" is an explicit instruction. If the
portal cannot answer, onboarding still creates the account and the container request
(the failure is logged) — the console can then create the agent by hand.

### 4.3 Login and the console session

```
Browser → POST /api/user/v1/auth/login            (portal Go, one origin)
  → bus /auth/v1/token → nanoauth
  → RS256 access token + single-use refresh ticket
Browser stores them; every request carries the access token.
  │
  ├─ console API: the portal validates the JWT against JWKS and enforces the role
  ├─ chat socket: the gateway validates it through the bus
  └─ 401 → both tabs try to refresh; the portal serialises the attempt across tabs and
     only signs out when nanoauth actually rejects the ticket
```

### 4.4 Provisioning a container

```
console / onboarding → provisioner (via the bus) → queue row (pending)
  │
  ▼
Provisioner poll loop
  1. claim the row, resolve backend and quota from the owner's tier
  2. create the container: image runner.agentImage, name <prefix><userID>,
     env token + admin URL + TZ, command `hypervisor --user …`
  3. wait for healthy, status → running
  │
  ▼
Hypervisor starts, registers its tunnel with the bus, reads the agent rows from the
portal and spawns one child per agent
```

Restart and re-provision reuse the same row: the container is replaced and the data
volume is kept. Dispose moves the row to `disposing` → `disposed`; a failure leaves it
in `disposing`, and the next poll retries.

### 4.5 Dictation

```
Browser (WebAudio, 24 kHz PCM16) ──WS /ws/voice?session=…──► portal nginx ──► bus
Bus: single-use session id (minted by the portal, 60 s, one use), then a transparent
     WebSocket relay to the configured ASR engine (hosted realtime endpoint, or the
     an OpenAI-compatible realtime provider)
Result: live text into the composer, then an optional polish pass; nothing is sent
        automatically.
```

The audio never crosses the portal's Go server, and the browser never sees the
provider's credentials.

### 4.6 Editing configuration

```
console → portal Go → admin PUT /api/v1/config/{component}/{key}
Admin: one row updated in admin_config
Bus: "config changed" event on /api/v1/events/stream
Consumers (gateway, agent, provisioner, auth): re-read their component
```

There is no restart step: the configuration is read at startup and re-read on the
change event (or within the reader's cache TTL, for the services that poll).

---

## 5. Configuration Management

### 5.1 Where configuration lives

There is one runtime configuration store: `admin_config` in the admin module, one row
per `(component, key)`. Its two properties matter:

- **Seeded, not coded.** `nanoadmin config seed` inserts the defaults a fresh
  installation needs; it never overwrites a value an operator has changed.
- **Read by the service that uses it, over HTTP.** The gateway, the agent, the
  provisioner, the auth service and the voice sidecar each fetch their own component
  (`GET {admin}/api/v1/config/{component}`) and re-read it when the bus broadcasts a
  change. The portal edits it (`PUT /api/v1/config/{component}/{key}`, forwarded).

The seed is a starting point, not the truth: an operator can add a key (for example
`runner.namePrefix`, which the seed does not define), and the code that reads the
component must tolerate its absence with a sane default.

Connection-level settings — addresses, database URIs, the shared token — are **not**
in the store: they are environment variables, because a service needs them before it
can reach anything.

### 5.2 Components and their keys

| Component | Key families | Edited in the console |
|---|---|---|
| `bus` | `host`, `port` | — (env) |
| `gateway` | `channels.{cli,wecom,feishu,wechatkf,web}.*` (enabled, credentials, callback address, streaming, markdown, max length), `ack.*`, `auth.jwksUrl` | Channels |
| `runner` | `runner.runnerID`, `runner.pollInterval`, `runner.backend`, `runner.quota.<tier>.{memory,cpu}`, `agentImage`, `namePrefix`, `network`, `runner.agentTimezone`, `seccompProfile` | Components / Models |
| `auth` | `firstUserIsAdmin`, `jwksUrl`, `ldap.*` (URL, bind, filters, attributes, provisioning and linking policy) | Directory login, Configs |
| `agent` | `agent.maxIterations` and other agent defaults, `agent.scheduledTaskMode`, `agent.language.default`, `agent.llm{Subagent,Summarize}ReasoningEffort`, `paths.*`, `media.*` | Configs, the agent form |
| `voice` | `enabled`, `shortcut`, `realtime.*` (engine, provider, model, language, limits, hotwords), `batch.*`, `polish.*` | Voice |

`secret`-typed rows are masked when listed; the console writes them through, and the
service that owns the credential reads the plain value.

### 5.3 Environment variables

Each service reads a small, explicit set; the names are stable and documented at the
point of use. The important ones:

| Service | Variables |
|---|---|
| `nanobus` | `NANOSEC_BUS_DATABASE_URI`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_BUS_SERVER_{HOST,PORT}`, `NANOSEC_BUS_NANOAUTH_BASE_URL`, `NANOSEC_BUS_ADMIN_BASE_URL`, `NANOSEC_BUS_PORTAL_BASE_URL`, `NANOSEC_BUS_PROVISIONER_BASE_URL` |
| `nanogateway` | `NANOSEC_GATEWAY_BUS_URL`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_ADMIN_URL`, `NANOSEC_PORTAL_URL` |
| `nanoagent` | `NANOSEC_AGENT_BUS_URL` (or `--bus-url`), `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_ADMIN_URL`, `NANOSEC_PORTAL_URL` |
| `nanoprovisioner` | `NANOSEC_RUNNER_BUS_URL`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_ADMIN_URL`, `NANOSEC_PROVISIONER_{MONGO_URI,ADDR}`, `NANOSEC_RUNNER_{BACKEND,AGENT_IMAGE,NETWORK,AGENT_TIMEZONE,STORAGE_*}` |
| `nanoauth` | `NANOAUTH_{MONGO_URI,ADDR,TOKEN_TTL,REFRESH_TTL,WECHAT_APP_ID,WECHAT_APP_SECRET,JWT_KEY_ID}`, `NANOSEC_ADMIN_URL`, `NANOSEC_BUS_INTERNAL_TOKEN` |
| `nanoportal` | `NANOPORTAL_MONGO_URI` (falls back to `NANOSEC_BUS_DATABASE_URI`), `NANO_PORTAL_BUS_URL`, `NANOSEC_ADMIN_URL`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANO_PORTAL_JWKS_URL` |
| `nanoadmin` | `NANOSEC_ADMIN_{MONGO_URI,ADDR}`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_BUS_URL` |
| `nanoartifacts` | `NANOARTIFACTS_{MONGO_URI,SESSION_SECRET,COOKIE_PATH,QUOTA_BYTES,ADDR,WEB_DIR}`, `NANOAUTH_JWKS_URL` |
| `nanoui` | `NANOUI_BACKEND_{ADDR,MYSQL_DSN,NANOAUTH_URL}` |

Two names are shared by the whole stack rather than following a prefix:

- **`NANOSEC_BUS_INTERNAL_TOKEN`** — the shared secret every module presents to the
  bus's internal endpoints (`/api/v1/**`, `/internal/**` on the other services, the
  tunnel, the terminal and the dictation socket). A service that does not have it
  refuses the protected endpoints instead of serving them; the provisioner passes it
  into every agent container.
- **`NANOSEC_BUS_DATABASE_URI`** — the one MongoDB URI. The modules that hold their
  own connection derive theirs from it when their own variable is unset
  (`NANOPORTAL_MONGO_URI`, `NANOSEC_ADMIN_MONGO_URI`,
  `NANOSEC_PROVISIONER_MONGO_URI`, `NANOAUTH_MONGO_URI`, `NANOARTIFACTS_MONGO_URI`).

### 5.4 Command-line surface

```bash
nanoadmin migrate up | status           # admin manifests (config, catalogue, audit)
nanoadmin config seed                  # platform defaults, never overwrites
nanoadmin permissions seed             # permission-key catalogue
nanoadmin agent-types seed             # built-in agent types
nanoadmin prompts seed [--force]       # bundled head/per-type prompts
nanoadmin skills seed                  # bundled skills
nanoadmin mcp seed                     # first-party MCP entries

nanobus migrate up | status            # bus manifests (queues, runners, sys_*)
nanoportal migrate up                  # portal manifests (agents, groups, sessions)
nanoprovisioner migrate up             # provisioning queue
nanoauth migrate up                    # auth collections
nanoartifacts migrate up               # work-library collections
```

Each module applies its own manifests at startup as well, so a restart after a deploy
is enough; the explicit commands are for the init containers and for operators.

---

## 6. Security and Trust Boundaries

- **Identity** — nanoauth issues RS256 tokens; the portal validates them against
  JWKS and enforces roles and ownership; the gateway asks the bus to validate a
  browser's token. The Mini Program and the work library use the same key set.
- **Internal token** — the bus and every module's `/internal/*` surface require the
  shared `NANOSEC_BUS_INTERNAL_TOKEN` (constant-time compare). Internal routes are
  never exposed to browsers by the portal's nginx: `/internal/` goes to the portal's
  own Go server, which checks the token itself.
- **Anonymous surfaces** — a health endpoint, the login/register endpoints, the JWKS
  endpoint and the dictation socket (`/ws/voice`, authenticated by a single-use id).
  Everything else needs either the internal token or a user token.
- **Per-IP rate limiting** on the bus's REST surface, as the outermost middleware.
- **Secrets** — provider keys and channel credentials live in the platform
  configuration (`secret` rows), not in the repository; the agent container gets the
  shared token and the admin URL, never the database URI. Config listings mask secret
  values.
- **Container trust** — the provisioner has the Docker socket, so a compromise there
  is a host compromise; it is the only service that gets that mount.
- **Authorization inside the agent** — tools are gated by the agent type's and the
  agent's permission rules; a read-only caller can only delegate to read-only
  subagents, and the rules travel with a delegated task.

---

## 7. Error Handling and Logging

**Errors** are returned, wrapped with `fmt.Errorf("…: %w", err)`, and matched with
`errors.Is`/`errors.As`; packages define sentinel errors for the cases a caller has to
distinguish (`ErrUserNotFound`, `ErrChannelDisabled`, `ErrSessionResync`,
`ErrToolCallTruncated`, …). A provider failure is classified (rate limit, context
overflow, truncated tool call, unavailable) and turned into a user-readable notice
rather than a stack trace. A failed best-effort write (audit, a status report) is
logged and never fails the user's action; a failed write that the action depends on
returns an error.

**Logging** uses `log/slog` with the same level ladder everywhere: a custom
`LevelVerbose` (below debug) for per-message tracing, then debug/info/warn/error.
`LOG_LEVEL` raises or lowers the floor. The `internal/log` package exists in the
services that log per-message traffic; the others use `slog` directly. The bus's
message logs, the gateway's channel logs and the agent's turn logs are the three
places to look at when a message does not arrive.

---

## 8. Deployment

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the full guide. The reference deployment is
one host running the compose stack:

| Service | Container port | Published |
|---|---|---|
| `nanobus` | 9000 | 14400 |
| `nanoauth` | 8081 | 14401 |
| `nanogateway` | 8080 | 14402 |
| `nanoportal` (nginx) | 80 | 14403 |
| `nanoadmin` | 8080 | 14404 |
| `nanoprovisioner` | 8080 | — |
| `nanoartifacts` | 8080 | — (reached through the portal's nginx) |
| agent hypervisor | 9090 | — (reached through the bus tunnel) |

Startup order is enforced by the compose file: `admin-init` (admin manifests +
seeds) → `bus-init` (bus manifests) → the services. The admin seeds run first because
the bus's own settings and the agent's catalogue live there. Every service needs
`NANOSEC_BUS_DATABASE_URI` and `NANOSEC_BUS_INTERNAL_TOKEN` from the environment; a
missing token makes the internal endpoints refuse requests rather than open them.

Agent containers are built from the agent image (`docker compose build nanosec`,
image `kobeyoung81/nanoagent:nanosec`) but are **not** started by `up`: the
provisioner creates them per user. A new agent image therefore reaches existing users
only when their container is re-provisioned or restarted.

Alternative targets — Docker Swarm (`deploy/swarm/docker-stack.yml`) and Kubernetes
(`deploy/k8s/*`, with RBAC for the provisioner) — use the same images and the same
environment variables. CI (the Jenkins job on the build host) builds the images from
the super-repo; pushing the super-repo's `master` is what triggers it.

---

## 9. Revision History

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-02-08 | Initial draft |
| 2.0 | 2026-02-09 | Multi-user decoupled architecture (Gateway, Bus, Agent) |
| 3.0 | 2026-03-31 | 5-module split, bus-managed config, WeChat KF sync state |
| 4.0 | 2026-07-30 | Sync with code: 12 migrations, BindingID, ConfigItems API, ContextualTool, DockerClient |
| 5.0 | 2026-08-15 | Enterprise platform: 26 MySQL migrations, nanoauth, REST + SSE, multi-agent runtime, hypervisor/tunnel, docker/swarm/k8s |
| 6.0 | 2026-11-11 | Rewritten after the module split (P1/P2): MongoDB with one writer per prefix; config, catalogue and audit in `nanoadmin`; agents, sessions and bindings in `nanoportal`; provisioning queue and runner registry in `nanoprovisioner`; all `auth_*` collections in `nanoauth`; onboarding creates a default agent; RPC over HTTP instead of a WebSocket client; the work library and the local ASR sidecar; corrected the "gateway polls outbound" drift (it is SSE) |
