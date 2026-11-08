# Architecture Design Document: MyriadMind

**Version**: 5.0
**Date**: 2026-08-15
**Status**: Current

---

## 1. System Overview

### 1.1 High-Level Architecture

MyriadMind uses a **decoupled multi-service architecture** (Protocol, Bus, Gateway, Agent, Runner, Auth) for multi-user support and horizontal scaling. All services communicate over a shared wire protocol defined in the **nanoprotocol** library, transported over **WebSocket** and, since the enterprise migration, **HTTP REST + SSE**.

The super-repo also contains three supporting surface modules: **nanoauth** (authentication), **nanoportal** (web management portal), and **nanoui** (WeChat Mini Program + BFF).

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              External Services                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐       │
│  │   CLI    │ │  WeCom   │ │  Feishu  │ │WeChat KF │ │ LLM Provider │       │
│  │ (stdin)  │ │(Ent.WeChat)│ │          │ │(Customer)│ └──────┬───────┘       │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘         │               │
│       │  ┌─────────┴────────────┴────┬───────┴──────┐        │               │
│       │  │        Browser            │   WeChat     │        │               │
│       │  │    (nanoportal chat)      │   Miniapp    │        │               │
│       └──┴────────────┬──────────────┴──────────────┴────────┴───────────────┘
│                       │                                                       │
└───────────────────────┼───────────────────────────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    GATEWAY (nanogateway)                                      │
│  CLI · WeCom · Feishu · Web Chat · WeChat KF  (JWT via JWKS for web)         │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ WebSocket / HTTP
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                      BUS (nanobus)                                            │
│  ┌────────────────┐ ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐ │
│  │ User Registry  │ │ Per-User Queues│ │ WebSocket +  │ │  /auth/v1/* proxy│ │
│  │ Agent Registry │ │ (MySQL)        │ │ REST + SSE   │ │  → nanoauth      │ │
│  └────────────────┘ └────────────────┘ └──────────────┘ └──────────────────┘ │
└──────────┬───────────────────────────────┬────────────────────────────────────┘
           │ WebSocket / HTTP              │ WebSocket / HTTP
           ▼                               ▼
┌─────────────────────────┐   ┌──────────────────────────┐
│  AGENT (nanosec)        │   │  RUNNER (nanorunner)     │
│  multi-agent router     │   │  docker | swarm | k8s    │
│  ReAct loop, tools,     │   │  per-tier quotas         │
│  sessions, skills, cron │   └────────────┬─────────────┘
│  hypervisor (:9090)     │                ▼
└─────────────────────────┘         Container backends
           │
           ▼
        LLM APIs

AUTH  (nanoauth :8081):  register · token · refresh · userinfo · wechat oauth · jwks
ADMIN (nanoportal :80):  React UI → bus REST + MySQL read
MOBILE(nanoui :8088 + miniapp):  WeChat login → nanoauth, plans/orders → MySQL
```

### 1.2 Process Model

| Process | Binary | Responsibility | Scaling |
|---------|--------|----------------|---------|
| **Bus** | `nanobus` | User/agent registry, message queues, WebSocket server, REST + SSE surface, config store, auth proxy | Multiple behind LB (stateless) |
| **Gateway** | `nanogateway` | Platform adapters, user resolution, message routing, JWT validation | Multiple per channel |
| **Agent** | `nanosec --user=X` | Multi-agent router, LLM calls, tools, sessions, skills, hypervisor | One per user (provisioned) |
| **Runner** | `nanorunner` | Container provisioning via docker/swarm/k8s backends, quota tiers | Multiple behind LB |
| **Auth** | `nanoauth` | Registration, password hashing, JWT signing, JWKS, refresh tokens, WeChat OAuth | Multiple behind LB |
| **Portal** | `nanoportal` | Admin UI + API (users, agents, configs, audit, alerts, chat, workspace) | Single (nginx + Go) |
| **Miniapp BFF** | `nanoui-backend` | WeChat login, account, subscriptions, preferences | Single |

### 1.3 Communication

| From | To | Protocol | Purpose |
|------|-----|----------|---------|
| Gateway | Bus | WebSocket / HTTP | Post inbound, poll/subscribe outbound, resolve user, get/set config |
| Agent | Bus | WebSocket / HTTP | Poll inbound, post outbound, save sessions, agent config |
| Runner | Bus | WebSocket / HTTP | Poll container requests, post status, register runner |
| Portal | Bus | HTTP REST | Users, agents, configs, audit, sessions, workspace, containers |
| Bus | nanoauth | HTTP | Reverse proxy `/auth/v1/*` |
| Agent | LLM | HTTPS | Chat completions (OpenAI-compatible API) |
| Gateway | Platforms | Platform-specific | CLI, WeCom, Feishu, Web Chat, WeChat KF |
| Agent | Gateway | WS tunnel | Hypervisor tunnel + streaming chunks |
| Runner | Backend | Docker SDK / Swarm / K8s API | Provision/dispose containers |

> **nanoprotocol** (`gitee.com/kobeyoung81/nanoprotocol`) is the shared protocol library.
> It defines the message envelope, 70 type constants, all request/response types, `MediaItem`,
> and a `Client` with auto-reconnect plus HTTP REST/SSE helpers.

---

## 2. Module Structure

The project is split into **7 Go modules** (each a git submodule) plus supporting surface modules. A `go.work` workspace at the repo root ties them together for local development.

```
myriadmind/                            # Super-repo (workspace, docs, configs, deploy)
├── go.work                            # Go workspace: 7 modules + go-workwx replace
├── docker-compose.yml                 # mysql(profile) + bus-init + bus + auth + runner + gateway + portal
├── .gitmodules                        # Submodule registry
├── configs/                           # Example / dev configuration files
├── docs/                              # Architecture, PRD, deployment, design docs
├── plans/                             # Implementation plans
├── scripts/
│   ├── bump-protocol.sh               # Tag nanoprotocol, update all consumers
│   └── install-hooks.sh               # Install pre-commit hooks in all submodules
├── deploy/
│   ├── swarm/docker-stack.yml         # Docker Swarm stack
│   └── k8s/                           # Kubernetes manifests (00-05, optional-mysql)
│
├── nanoprotocol/                      # [submodule] Shared protocol library
│   ├── messages.go                    # Message envelope, 70 type constants, all payload types
│   ├── client.go                      # WebSocket Client + HTTP/SSE helpers
│   └── go.mod
│
├── nanobus/                           # [submodule] Message bus service
│   ├── cmd/nanobus/main.go            # CLI: serve, version, user, config, migrate
│   ├── internal/server/               # WS server + REST surface + auth proxy + dispatch
│   ├── internal/stream/               # SSE chunk buffer
│   ├── internal/store/                # users, queues, config, agents, sessions, audit, runners
│   ├── migrations/                    # 23 SQL migration files (001-023) + embed.go
│   └── go.mod
│
├── nanogateway/                       # [submodule] Gateway service
│   ├── cmd/nanogateway/main.go        # CLI: --bus-url, --message, version
│   ├── internal/gateway/              # Gateway loop + BusClient
│   ├── internal/channel/              # cli/wecom/feishu/web/wechatkf adapters
│   ├── internal/auth/                 # JWKS validator
│   ├── go-workwx/                     # Vendored WeCom API fork
│   └── go.mod
│
├── nanosec/                           # [submodule] AI agent service
│   ├── cmd/nanosec/main.go            # CLI: --user, --binding, --hypervisor-addr, version
│   ├── internal/agent/                # Agent, ReAct loop, AgentRouter, subagents, summarization
│   ├── internal/provider/             # LLM Provider interface, OpenAI client, mock
│   ├── internal/session/              # JSONL file-based session storage
│   ├── internal/tool/                 # Tool registry + built-ins
│   ├── internal/skill/                # Skill loader, registry, built-in skills
│   ├── internal/cron/                 # Job scheduler (robfig/cron/v3)
│   ├── internal/workspace/            # Per-agent workspace isolation + shared workspace
│   ├── internal/hypervisor/           # HTTP server (:9090) for containers + workspace browser
│   ├── internal/config/               # AgentConfig, per-agent layering
│   ├── workspace/                     # Runtime assets: AGENT.md, SOUL.md, skills, memory
│   └── go.mod
│
├── nanorunner/                        # [submodule] Container provisioning service
│   ├── cmd/nanorunner/main.go         # CLI: --bus-url, version
│   ├── internal/runner/               # Poll loop, Provisioner interface
│   ├── internal/runner/backend/       # docker/ · swarm/ · k8s/ provisioners
│   ├── deploy/k8s/                    # RBAC + runner deployment manifests
│   └── go.mod
│
├── nanoauth/                          # [submodule] OAuth2/OIDC auth service
│   ├── cmd/nanoauth/main.go           # Env-based config (NANOAUTH_*)
│   ├── internal/handler/              # Auth / OAuth / JWKS handlers
│   ├── internal/token/                # RS256 JWT sign/verify
│   ├── internal/store/                # Users / refresh tokens
│   └── go.mod
│
├── nanoportal/                        # [submodule] Web management portal
│   ├── server/                        # Go backend + admin API
│   └── web/                           # React (Vite) frontend
│
└── nanoui/                            # [submodule] Web UI + WeChat Mini Program
    ├── backend/                       # Go BFF (login proxy, account, subscriptions)
    └── miniapp/                       # WeChat Mini Program (home/agent/me/subscription)
```

### 2.1 Module Dependencies

```
                    ┌─────────────────────────────────────┐
                    │         nanoprotocol                 │
                    │  (shared types, client, constants)   │
                    └──────┬────────┬────────┬────────┬───┘
                           │        │        │        │
               ┌───────────┘        │        │        └────────────┐
               ▼                    ▼        ▼                     ▼
         ┌──────────┐   ┌───────────┐ ┌──────────┐   ┌───────────┐
         │ nanobus  │   │nanogateway│ │ nanosec  │   │nanorunner │
         └────┬─────┘   └─────┬─────┘ └────┬─────┘   └─────┬─────┘
              │               │            │               │
              ▼               ▼            ▼               ▼
           MySQL      go-workwx/v2    go-openai      docker/docker
                       oapi-sdk-go/v3  robfig/cron    (k8s client)

   nanoauth (MySQL, golang-jwt/v5, x/crypto)  ← proxied by nanobus (/auth/v1/*)
   nanoportal (MySQL)                         → bus REST + hypervisor HTTP
   nanoui/backend (MySQL)                     → nanoauth (WeChat login)
```

**Dependency Rules:**
- All services depend on `nanoprotocol` for message types and the client
- `nanobus`, `nanogateway`, `nanosec`, `nanorunner`, `nanoauth` are **independent modules** — no cross-imports
- `nanoprotocol` has zero external dependencies beyond `gorilla/websocket` and stdlib
- Each module has its own `internal/config/` and `internal/log/` packages
- `go.work` at the repo root enables cross-module development

---

## 3. Core Components

### 3.1 WebSocket Protocol (`nanoprotocol` module)

**Purpose**: Shared message types for all inter-service communication.

#### Message Envelope

```go
type Message struct {
    Type    string          `json:"type"`              // Discriminator constant
    Payload json.RawMessage `json:"payload,omitempty"` // Typed payload
    Error   string          `json:"error,omitempty"`   // Error string
}
```

#### Type Constants (70 total, organized by boundary)

- **Gateway ↔ Bus:** `resolve_user`, `post_inbound`, `poll_outbound`, `user_resolved`, `outbound`
- **Agent ↔ Bus:** `poll_inbound`, `post_outbound`, `inbound`
- **Streaming:** `outbound_chunk`, `outbound_complete`
- **Container management (Runner ↔ Bus):** `request_container`, `container_requested`, `list_containers`, `containers_listed`, `poll_pending_containers`, `pending_containers`, `update_container_status`, `dispose_container`, `container_disposed`
- **Auth (Service ↔ Bus ↔ nanoauth):** `authenticate`, `authenticated`, `validate_token`, `token_valid`, `register_account`, `account_registered`
- **Agent management (Portal ↔ Bus):** `create_agent`, `agent_created`, `list_agents`, `agents_listed`, `update_agent`, `agent_updated`, `delete_agent`, `agent_deleted`
- **Agent grouping (Portal → Bus, REST only):** `GET/POST /api/v1/agent-groups`, `PUT/DELETE /api/v1/agent-groups/{id}`, `POST /api/v1/agent-groups/reorder`. `agents.group_id` carries the assignment; a group is a user-private, single-level document. See `docs/AGENT_GROUPS_DESIGN.md`.
- **Agent-scoped config:** `get_agent_config`, `agent_config`, `set_agent_config`, `agent_config_set`, `config_changed`
- **User management:** `update_user`, `user_updated`, `get_user`, `user`, `update_user_status`, `get_user_info`, `user_info`
- **Sessions:** `save_session`, `session_saved`, `archive_session`, `session_archived`, `list_sessions`, `sessions_listed`, `get_session`, `session`
- **Hypervisor tunnel:** `tunnel_register`, `tunnel_registered`, `tunnel_request`, `tunnel_response`
- **Audit:** `get_audit_log`, `audit_log`
- **WeChat KF sync:** `get_wechatkf_sync_state`, `wechatkf_sync_state`, `update_wechatkf_cursor`, `update_wechatkf_callback_token`
- **Configuration:** `get_config_items`, `config_items`, `set_config_item`, `config_item_set`
- **Runner registry:** `register_runner`, `runner_registered`
- **Error:** `error`

#### Client

The `Client` struct provides RPC-style methods over a single WebSocket connection, with HTTP REST/SSE helpers:

```go
type Client struct { /* unexported fields */ }

func NewClient(url string) (*Client, error)
func (c *Client) Close() error
func (c *Client) Send(msg Message) (*Message, error)

// Messaging
func (c *Client) ResolveUser(channel, senderID string) (*ResolveUserResponse, error)
func (c *Client) PostInbound(inbound InboundMessage) error
func (c *Client) PollInbound(userID string, bindingID int64, agentID string) (*InboundMessage, error)
func (c *Client) PostOutbound(outbound OutboundMessage) error
func (c *Client) PollOutbound(channel, gatewayID string) (*OutboundMessage, error)

// Containers
func (c *Client) PollPendingContainers(runnerID string) ([]ContainerRequest, error)
func (c *Client) RequestContainer(userID string, bindingID int64, agentID, level string) error
func (c *Client) ListContainers(userID string, limit int) ([]ContainerRequest, error)
func (c *Client) UpdateContainerStatus(userID string, bindingID int64, status string) error
func (c *Client) DisposeContainer(userID string, bindingID int64, agentID string) error

// Users
func (c *Client) UpdateUserStatus(userID, status string) error
func (c *Client) GetUserInfo(userID string) (*UserInfoResponse, error)

// Auth
func (c *Client) Authenticate(email, password string) (*AuthenticateResponse, error)
func (c *Client) ValidateToken(token string) (*ValidateTokenResponse, error)
func (c *Client) RegisterAccount(email, password, displayName string) (*RegisterAccountResponse, error)

// Agents
func (c *Client) CreateAgent(req CreateAgentRequest) error
func (c *Client) UpdateAgent(req UpdateAgentRequest) error
func (c *Client) DeleteAgent(agentID string) error
func (c *Client) ListAgents(userID string) ([]AgentRecord, error)
func (c *Client) GetAgentConfig(agentID string) ([]ConfigItem, error)
func (c *Client) SetAgentConfig(agentID, key, value string) error

// Sessions
func (c *Client) SaveSession(req SaveSessionRequest) error
func (c *Client) ArchiveSession(sessionID string) error
func (c *Client) ListSessions(agentID string, limit, offset int) ([]SessionMeta, error)
func (c *Client) GetSession(sessionID string) (*GetSessionResponse, error)

// WeChat KF
func (c *Client) GetWeChatKFSyncState(openKfID string) (*WeChatKFSyncStateResponse, error)
func (c *Client) UpdateWeChatKFCursor(openKfID, cursor string) error
func (c *Client) UpdateWeChatKFCallbackToken(openKfID, callbackToken string, tokenExpiresAt time.Time) error

// Config + runner registry
func (c *Client) GetConfigItems(componentType string) ([]ConfigItem, error)
func (c *Client) SetConfigItem(componentType, key, value string) error
func (c *Client) RegisterRunner(runnerID, hostname, dockerHost string) (*RegisterRunnerResponse, error)

// Config change notifications (SSE)
func (c *Client) ConfigChanges() <-chan ConfigChange
```

Key behaviors:
- `Send()` blocks on a single read with a 30-second deadline
- Auto-reconnect: if the connection is nil, `Send()` re-dials before sending
- Read errors close the connection, forcing a fresh reconnect next call
- `Poll*` methods return `nil, nil` when no message is available (no-error-no-message)

### 3.2 Bus Service (`nanobus`)

**Purpose**: Central message routing with MySQL-backed user/agent registry, per-user queues, config storage, WeChat KF sync state, runner registry, REST + SSE surface, and the `/auth/v1/*` reverse proxy to nanoauth.

#### MySQL Schema (26 migrations)

| Migration | Table/Change |
|-----------|-------------|
| 001 | `users` + `user_channels` |
| 002 | `inbound_queue` + `outbound_queue` |
| 003 | `status` + `level` columns on users |
| 004 | `container_requests` |
| 005 | `media` JSON on outbound_queue |
| 006 | `message_id` columns + indexes |
| 007 | `wechatkf_sync_state` |
| 008 | `service_configs` (dropped by 009) |
| 009 | `service_config_items` (key-value) |
| 010 | `enabled` flag on user_channels |
| 011 | `runners` |
| 012 | `binding_id`, `provider`, `binding_status`, `agent_id` |
| 013 | auth fields on users (`email`, `password_hash`, `display_name`, `role`; `level` → `tier`) |
| 014 | `refresh_tokens` + `oauth_providers` |
| 015 | `agents`, `agent_tools`, `agent_workspaces` (+ auto default agent) |
| 016 | `agent_id` on queues + indexes |
| 017 | `agent_sessions` (MySQL conversation persistence) |
| 018 | `audit_log` |
| 019 | `alert_rules` |
| 020 | `subscription_plans` |
| 021 | `subscription_orders` |
| 022 | `binding_agent_preferences` |
| 023 | container `disposing` status + `disposed_at` |
| 024 | `jwt_keys` (nanoauth DB-stored RSA signing keypair) |
| 025 | move `jwt_keys` → `service_config_items.auth.jwtKeyPair`, drop `jwt_keys` |
| 026 | split `auth.jwtKeyPair` → `auth.jwtPrivateKey` + `auth.jwtPublicKey`, delete `jwtKeyPair` |

#### Key Tables

- **users** — `id`, `status ENUM(active,suspended,pending)`, `tier ENUM(free,pro,ultra)`, `email`, `password_hash`, `display_name`, `role`
- **user_channels** — `binding_id BIGINT AUTO_INCREMENT UNIQUE`, `user_id FK`, `provider`, `channel`, `sender_id`, `enabled`, `binding_status`; PK `(channel, sender_id)`
- **inbound_queue / outbound_queue** — per-user messages with `binding_id`, `agent_id`, `session_id`, `media JSON`, `metadata JSON`, `status ENUM(pending,claimed,done)`, atomic claiming via `SELECT ... FOR UPDATE`
- **container_requests** — `user_id`, `binding_id`, `agent_id`, `level`, `status ENUM(pending,creating,running,suspended,disposing,disposed)`, `runner_id`, `disposed_at`
- **agents / agent_tools / agent_workspaces** — per-user agent registry and tool/workspace config
- **agent_sessions** — `id "{agentID}:{channel}:{chatID}:v{version}" PK`, `agent_id`, `account_id`
- **service_config_items** — `(component_type, config_key) PK` key-value runtime config
- **runners** — `id`, `hostname`, `docker_host`, `status`, `last_heartbeat`
- **wechatkf_sync_state** — `open_kfid PK`, `cursor`, `callback_token`, `token_expires_at`
- **audit_log** — append-only `actor_id`, `actor_role`, `action`, `resource_type`
- **refresh_tokens / oauth_providers** — auth service tables
- **subscription_plans / subscription_orders / binding_agent_preferences** — mobile monetization

#### Store Layer Highlights

```go
type Store struct { /* db *sql.DB */ }

func Open(dsn string) (*Store, error)

// Users & bindings
func (s *Store) RegisterUser(userID string) error
func (s *Store) ResolveUserBinding(channel, senderID string) (ResolvedBinding, error)
func (s *Store) UpdateUserStatus(userID, status string) error
func (s *Store) GetUserInfo(userID string) (status, tier string, err error)

// Queues (atomic claiming with SELECT ... FOR UPDATE)
func (s *Store) PostInbound(msg nanoprotocol.InboundMessage) error
func (s *Store) ClaimInbound(userID string, bindingID int64, agentID string) (*nanoprotocol.InboundMessage, error)
func (s *Store) PostOutbound(msg nanoprotocol.OutboundMessage) error
func (s *Store) ClaimOutbound(channel, gatewayID string) (*nanoprotocol.OutboundMessage, error)

// Containers, runners, config, sessions, agents, audit (CRUD for the tables above)
func (s *Store) Migrate(migrations map[string]string) ([]string, error)
```

#### Key Design Points

1. **Atomic message claiming** — `ClaimInbound`/`ClaimOutbound` use `SELECT ... FOR UPDATE` within a transaction
2. **Auto-onboarding** — `ResolveUserBinding` auto-creates users (`status=pending`, `tier=free`), a `user_channels` entry, a default agent (migration 015), and a `container_requests` entry
3. **Embedded migrations** — SQL files embedded via `go:embed`, applied lexicographically, tracked in `schema_migrations`
4. **Key-value config** — `service_config_items` enables runtime reconfiguration; seeded by `nanobus config seed`
5. **Auth proxy** — `/auth/v1/*` is reverse-proxied to nanoauth (no auth logic in the bus)

---

### 3.3 Gateway Service (`nanogateway`)

**Purpose**: Chat platform adapters with user resolution via the bus and JWT validation for the web channel.

#### Channel Interface

```go
type InboundMessage struct {
    Channel, SenderID, ChatID, MessageID, Content string
    Media     []nanoprotocol.MediaItem
    Metadata  map[string]any
    AgentID   string // routes to a specific agent when set
    UserID    string // authenticated user (web channel) — skips sender resolution
}

type Channel interface {
    Name() string
    Start(ctx context.Context, handler InboundHandler) error
    Send(ctx context.Context, msg OutboundMessage) error
    Stop() error
}

// Optional streaming delivery (browser WebSocket channel)
type StreamSender interface {
    SendChunk(ctx context.Context, chunk nanoprotocol.OutboundChunk) error
    SendComplete(ctx context.Context, complete nanoprotocol.OutboundComplete) error
}
```

#### Channel Adapters

| Adapter | Channel Name | Protocol | Package |
|---------|-------------|----------|---------|
| CLI | `cli` | stdin/stdout | `internal/channel/cli` |
| WeCom | `wecom` | HTTP callback (go-workwx) | `internal/channel/wecom` |
| Feishu | `feishu` | WebSocket (oapi-sdk-go) | `internal/channel/feishu` |
| Web Chat | `web` | WebSocket + streaming | `internal/channel/web` |
| WeChat KF | `wechatkf` | Polling + HTTP callback | `internal/channel/wechatkf` |

The web channel is **enabled by default** (`channels.web.enabled=true`) and authenticates
browsers through the bus `validate_token` RPC (delegated to nanoauth `userinfo`) and lists
agents via the bus `list_agents` RPC. It implements `StreamSender` for token streaming and
publishes `:8080` for the portal's Chat page. The gateway also supports JWT validation
against the nanoauth JWKS endpoint (`auth.jwksUrl` config item) for other consumers.

### 3.4 Agent Service (`nanosec`)

**Purpose**: Per-user multi-agent runtime with ReAct loop, LLM, tools, sessions, skills, cron, and a hypervisor HTTP server.

#### Multi-Agent Router

`nanosec --user=alice` starts an `AgentRouter` that:
1. Lists the user's agents from the bus (`ListAgents`)
2. Constructs a fully-wired `Agent` per agent record (per-agent config layering: `agent.default.*` → `agent.<id>.*`, model override, system prompt, workspace)
3. Polls inbound messages and dispatches them to the matching agent

Each agent gets its own:
- **Workspace** — isolated under `{dataRoot}/agents/{agentID}/` with a read-only shared workspace (workspace manager)
- **Tool registry** — shell (with shared-workspace support), filesystem, web, message, media, cron, spawn
- **Session store** — versioned JSONL (`channel:chatID:v1`, auto-archived when idle), dual-written to the bus `agent_sessions`
- **Context builder** — identity (AGENT.md), bootstrap (SOUL/USER/TOOLS.md), long-term memory, daily notes, skills

#### ReAct Loop (`processMessage`)

1. Get or create session
2. Add user message to session
3. Build context (system prompt + history + truncated oldest turns if over budget)
4. Loop up to `MaxIterations` (default 20):
   - Call LLM with messages and tool definitions
   - If no tool calls: final response, save session (JSONL + bus), post outbound (chunked via `outbound_chunk` / `outbound_complete`)
   - If tool calls: execute each tool, append results, continue loop

#### Provider System

```go
type Provider interface {
    Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error)
}

type OpenAIProvider struct { /* wraps go-openai client */ }
func NewOpenAI(apiKey, baseURL, defaultModel string) *OpenAIProvider
```

#### Tool System

| Tool | Description |
|------|-------------|
| `bash` | Execute bash commands (deny list, timeout) |
| `read_file` / `write_file` / `edit_file` / `ls` | Workspace-isolated filesystem tools (optional shared workspace) |
| `append_note` | Timestamped note to daily memory |
| `web_fetch` / `web_search` | Fetch URL / search via Tavily API |
| `send_message` | Send a message through the bus |
| `media_download` / `media_upload` | WeCom media API |
| `cron` | Schedule/list/remove tasks: a fired task injects an inbound message, so it starts a real turn in a conversation of its own |
| `spawn` | Launch a background subagent |

Tools needing channel/chat context (`send_message`, media, cron, spawn) implement `ContextualTool` (`SetContext(channel, chatID)`).

#### Scheduled tasks

A task is stored per agent in `agent/cron.json`. Firing one does **not** send a notice to a
channel: it posts an inbound message for the owning agent (`agent_id` set, `sender_id: cron`,
metadata `source: cron`), which is the only path that starts a turn. The task therefore runs
for real, in a conversation of its own — the payload names it (`payload.chatId`, `task-<8 hex>`,
minted once at creation) — so consecutive runs accumulate in one place instead of mixing into
the conversation the task was requested from. Because no user is present, the run is
*unattended*: the `question` tool refuses rather than blocking the turn (and the conversation's
lock) forever, and the conversation takes the task's name. The portal shows the same list
(read-only) in the sidebar's tasks pane.

A run's **mode** is resolved most-specific first and travels in the message metadata
(`agent_mode`), so an already-created task switches modes on its next run with nothing to
recreate:

| Level | Where | Who edits it |
|---|---|---|
| Task | `payload.mode` in `agent/cron.json` | the agent (`cron add … mode=plan`) |
| Agent | `agents.settings.scheduled_task_mode` | the user, in the agent form |
| Platform | config item `agent.scheduledTaskMode` (also `agent.default.` / `agent.<id>.` variants) | an operator, in the config center |
| Fallback | `build` | — |

`build` is the default on purpose: a scheduled task that inherited an agent's conversation
default (often `plan`) could only produce plans. The agent form shows the effective value and
where it comes from, read back through `GET /api/user/v1/agents/{id}/settings/{key}` — a
whitelisted single key (the `agent` component also holds secrets, so it is never returned whole).

#### Hypervisor

The hypervisor HTTP server (`--hypervisor-addr :9090`) exposes the container health / workspace
browser API used by nanoportal, and registers a WebSocket tunnel with the bus
(`tunnel_register` / `tunnel_request` / `tunnel_response`).

### 3.5 Runner Service (`nanorunner`)

**Purpose**: Container provisioning via pluggable backends, polled from the bus.

A runner registers under a **stable identity** (`--runner-id` or the `runner.runnerID`
config item) so every restart updates the same `runners` row instead of inserting a new
one. The bus touches `last_heartbeat` on each poll, runs a 60s sweeper that marks rows
with a heartbeat older than 2 minutes as `offline` (never deletes), and exposes
`DELETE /api/v1/runners/{id}` for pruning dead runners by hand.

```
Runner polls bus: TypePollPendingContainers → Bus returns TypePendingContainers
         |
         v
Runner resolves backend (runner.backend): docker | swarm | k8s
         |
         v
Runner determines quota by tier (runner.quota.<tier>.memory/.cpu):
   free:  512MB RAM, 1 CPU
   pro:   2048MB RAM, 2 CPU
   ultra: 4096MB RAM, 4 CPU
         |
         v
Provisioner.Provision(req, opts)  →  container / service / Deployment
         |
         v
Runner posts TypeUpdateContainerStatus (status: "running") and updates user status
```

#### Provisioner Interface

```go
type Provisioner interface {
    Provision(ctx context.Context, req nanoprotocol.ContainerRequest, opts ProvisionOptions) error
    Deprovision(ctx context.Context, req nanoprotocol.ContainerRequest, opts ProvisionOptions) error
}
```

| Backend | Provision unit | Notes |
|---------|----------------|-------|
| `docker` (default) | container | Local/remote Docker Engine via socket |
| `swarm` | single-replica service | Per-user service with resource limits |
| `k8s` | Deployment | In-cluster client; RBAC in `nanorunner/deploy/k8s/rbac.yaml` |

Container naming is deterministic per `(userID, bindingID)` (e.g. `nanosec-agent-{userID}-{bindingID}`).
Disposal follows the `disposing` → `disposed` lifecycle (migration 023).

### 3.6 Auth Service (`nanoauth`)

**Purpose**: OAuth2/OIDC authentication shared by the portal, gateway web channel, and miniapp.

- `POST /auth/v1/register` — create user (bcrypt)
- `POST /auth/v1/token` — password grant → access + refresh token
- `POST /auth/v1/token/refresh` — refresh pair
- `GET /auth/v1/userinfo` — OIDC userinfo
- `POST /auth/v1/oauth/wechat` — WeChat Mini Program login
- `GET /auth/v1/.well-known/jwks` — RS256 public key set

Generates its RS256 keypair on first boot and stores it in MySQL
(`service_config_items`, component `auth`, keys `jwtPrivateKey`/`jwtPublicKey`,
migration 026) — no key files or secrets need to be mounted. The bus reverse-proxies `/auth/v1/*`.

`POST /auth/v1/token` accepts either a local platform password or a corporate
directory password. With `ldap.enabled=true` (`service_config_items`, component
`auth`, prefix `ldap.`) the identifier is the corporate email, the password is
verified by binding against the entry the email matches, and a first successful
login either provisions an account or links the directory identity to the
existing one with the same email. Which accounts sign in through the directory is
recorded in `oauth_providers` (`provider='ldap'`, `provider_id` = the directory
unique id) and surfaced to the console as `auth_source`. See
`nanoauth/README.md` for the settings and the login rules.

Those settings are edited on the portal's **目录登录** page (management section,
`/admin/directory`), which is a typed editor over the same rows the config center
shows; the page also drives read-only diagnostics on the auth service
(`/auth/v1/directory/{effective,validate,test,browse,analyze,search,check}` via
the portal's `/api/admin/v1/directory/*`). The diagnostics need a verified
management token, own no storage, and never write to the platform or to the
directory.

---

## 4. Data Flow Diagrams

### 4.1 Message Flow (User → Agent → User)

```
User sends "Hello" on WeCom
         |
         v
GATEWAY (WeCom adapter)
   1. HTTP callback receives message from WeCom
   2. ResolveUser → Bus returns {user_id: "alice", binding_id: 1}
   3. PostInbound → Bus with userID, bindingID, agentID, content
         | WebSocket
         v
BUS
   4. INSERT INTO inbound_queue (user_id, binding_id, agent_id, ...)
         |
         v
AGENT (alice, multi-agent router)
   5. PollInbound(userID, bindingID, agentID)
   6. Bus claims: UPDATE inbound_queue SET status='claimed'
   7. Load session (JSONL / agent_sessions)
   8. Add user message, build context
   9. ReAct loop: LLM → tool calls → results → LLM (up to MaxIterations)
  10. Save session (JSONL + bus)
  11. PostOutbound → Bus (chunked: outbound_chunk / outbound_complete)
         |
         v
BUS
  12. INSERT INTO outbound_queue (user_id, channel, ...)
         |
         v
GATEWAY (polling outbound for "wecom")
  13. PollOutbound(channel="wecom", gatewayID)
  14. Bus claims; WeCom adapter sends message via WeCom API
```

### 4.2 Auto-Onboarding Flow

```
New user sends first message (no user_channels entry)
         |
         v
Bus ResolveUserBinding:
   1. Lookup user_channels WHERE channel=? AND sender_id=? → not found
   2. INSERT INTO users (id) VALUES (uuid())
   3. INSERT INTO user_channels (user_id, channel, sender_id, provider) ...
   4. INSERT INTO agents (id='{userID}-default', ...)   -- migration 015
   5. INSERT INTO container_requests (user_id, level, status) VALUES (..., 'free', 'pending')
   6. Return ResolvedBinding{UserID, BindingID, IsNew: true}
         |
         v
Runner later polls and provisions a container for the new user
```

### 4.3 Auth Flow (Browser → Portal / Web Chat)

```
Browser → nanoportal / gateway web channel
   1. POST /auth/v1/token (via bus proxy) → nanoauth → JWT (RS256)
   2. Gateway web channel validates JWT against JWKS (auth.jwksUrl)
   3. Browser opens WebSocket chat; messages carry userID + agentID
```

### 4.4 Container Provisioning Flow

```
Auto-onboard creates container_requests entry (status: pending)
         |
         v
Runner poll loop (every PollInterval seconds):
   1. PollPendingContainers(runnerID) → Bus returns pending requests
   2. For each request:
      a. Backend + quota resolved from runner config items
      b. Provisioner.Provision(...)   -- container / service / Deployment
      c. UpdateContainerStatus(userID, bindingID, "running")
         |
         v
User status updated to "active"

Admin dispose (portal):
   POST /api/admin/v1/containers/{userID}/dispose → disposing → disposed
```
---

## 5. Configuration Management

### 5.1 Bus-Managed Configuration

All services (gateway, agent, runner) load their configuration from the bus at startup via `GetConfigItems(componentType)`. The bus stores configs as key-value pairs in `service_config_items`, seeded by `nanobus config seed` and editable via the portal **Configs** page or `nanobus config set`.

```
Service startup:
   1. Connect to bus (--bus-url flag)
   2. Send: {type: "get_config_items", payload: {component_type: "gateway"}}
   3. Bus returns: {type: "config_items", payload: {items: [...]}}
   4. Service reconstructs config from flat dot-notation keys
```

The bus loads its own config (DSN, host, port, nanoauth URL) locally at startup.

### 5.2 Config Item Keys (seeded)

| Component | Example keys |
|-----------|--------------|
| `bus` | `host`, `port` |
| `gateway` | `channels.cli.enabled`, `channels.wecom.*`, `channels.feishu.*`, `channels.wechatkf.*`, `channels.web.listenAddr`, `ack.enabled`, `ack.text`, `auth.jwksUrl` |
| `runner` | `runner.pollInterval`, `runner.backend` (docker/swarm/k8s), `runner.quota.<tier>.memory/.cpu`, `runner.agentTimezone` (IANA zone injected as `TZ` into agent containers; empty = UTC), `agentImage`, `network` |
| `agent` | `provider.apiKey`, `provider.baseUrl`, `provider.defaultModel`, `agent.maxIterations`, `agent.contextWindow`, `paths.*`, `tools.*`, `media.*`, `agent.scheduledTaskMode` (mode scheduled tasks run in; `agent.default.` / `agent.<id>.` variants layer like any other agent setting) |
| `auth` | `jwksUrl` |

### 5.3 Environment Variable Prefixes

| Service | Env Prefix | Example |
|---------|-----------|---------|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_SERVER_PORT=9001` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL=ws://...` |
| `nanosec` | `NANOSEC_` | `NANOSEC_OPENAI_API_KEY=sk-...` |
| `nanorunner` | `NANOSEC_RUNNER_` | `NANOSEC_RUNNER_BUS_URL=ws://...` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_BUS_URL=http://localhost:9000` |
| `nanoportal` | `NANO_PORTAL_` | `NANO_PORTAL_BUS_URL=http://localhost:9000` |
| `nanoui` (backend) | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR=:8088` |

One variable is shared by every service instead of following a prefix: `NANOSEC_BUS_INTERNAL_TOKEN`
is the shared secret the bus's internal endpoints require (`/api/v1/**`, the tunnel, hypervisor and
terminal sockets). It is read by `nanobus` (to verify), and by `nanosec`, `nanogateway`,
`nanorunner` and `nanoportal` (to present it); `nanorunner` passes it on to every agent container
it provisions. A bus without it refuses those endpoints rather than serving them anonymously.

### 5.4 Config Seeding CLI

```bash
nanobus migrate up                     # Apply pending migrations
nanobus migrate status                 # Show migration status
nanobus config seed                    # Seed default config items for all components
nanobus config get <component-type> [key]  # Get config item(s)
nanobus config set <component-type> <key> <value>  # Set a config item
```

---

## 6. Security & Enterprise Features

- **Authentication** — nanoauth issues RS256 JWTs; the gateway web channel validates against the JWKS endpoint; the bus proxies `/auth/v1/*`
- **Authorization** — nanoportal uses an `Authorizer` with `RequireRole` / `RequireOwnership` middleware (admin/operator roles, ownership scoping)
- **Audit** — append-only `audit_log` table + REST query API (`GET /api/admin/v1/audit`)
- **Internal authentication** — the bus's REST API and its tunnel / hypervisor / terminal sockets require the shared `NANOSEC_BUS_INTERNAL_TOKEN` (constant-time comparison, `Authorization: Bearer`, or `?token=` where a handshake cannot carry a header). Two routes are exempt: the browser's dictation socket (`/ws/voice`), which authenticates with a single-use id minted through the portal, and the directory login console's subtree (`/auth/v1/directory/`, plus its `/api/auth/v1` spelling), which carries the *caller's* JWT rather than the bus token — the portal cannot put both in one header, and nanoauth re-verifies that JWT and the management role itself on every route under it, so this opens nothing to anonymous callers; an unconfigured bus refuses the protected endpoints instead of leaving them open. The bus's REST surface is therefore no longer reachable by anonymous callers on the host network (injecting one inbound message used to be enough to make an agent run).
- **Rate limiting** — per-IP rate limiting middleware on the bus (outermost: an unauthenticated flood is bounded too)
- **Secrets** — config items of `value_type=secret` are masked in `nanobus config get` output; credentials are injected via env vars / Kubernetes Secrets / Swarm secrets

---

## 7. Error Handling & Logging

### Error Handling

1. **Explicit Returns** — all functions return `(result, error)`; no panics except unrecoverable bugs
2. **Error Wrapping** — `fmt.Errorf("context: %w", err)` for traceability
3. **Error Matching** — `errors.Is()` / `errors.As()` for specific handling
4. **Sentinel Errors** — package-level errors for common cases (`ErrConnectionClosed`, `ErrUserNotFound`, `ErrChannelDisabled`, ...)

### Logging

All services use Go's `slog` for structured logging. A custom `LevelVerbose` (`slog.Level(-8)`) is defined in each service's `internal/log/` package for high-frequency protocol messages.

| Level | Usage |
|-------|-------|
| Verbose | Per-message protocol tracing |
| Debug | Internal state, message contents |
| Info | Startup, connections, high-level flow |
| Warn | Recoverable issues, retries |
| Error | Failures that affect functionality |

---

## 8. Deployment

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the full operations guide. Summary of targets:

| Target | Manifests | Provisioner backend | Notes |
|--------|-----------|---------------------|-------|
| Local / single host | `docker-compose.yml` | `docker` | One external MongoDB; both the URI and the shared token are required |
| Docker Swarm | `deploy/swarm/docker-stack.yml` | `swarm` | External MongoDB; export the URI + token before `stack deploy` |
| Kubernetes | `deploy/k8s/*` | `k8s` | External MongoDB (`02-secrets.yaml`); RBAC in nanorunner |
| CI/CD | Jenkins job (configured on the server) | `docker` | Jenkins-in-Docker + host socket |

Every deployment:
1. Requires a reachable MySQL 8.0 (`nanosec` schema shared by all services)
2. Applies migrations + seeds config (`nanobus migrate up && nanobus config seed`)
3. Uses the prebuilt images `kobeyoung81/{nanobus,nanogateway,nanosec,nanorunner,nanoauth,nanoportal}:latest`
4. Requires no JWT key provisioning — `nanoauth` generates and stores its RS256
   keypair in `service_config_items.auth.jwtPrivateKey`/`auth.jwtPublicKey` (MySQL)
   on first boot

---

## 9. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-08 | Claude | Initial draft |
| 2.0 | 2026-02-09 | Claude | Multi-user decoupled architecture (Gateway, Bus, Agent) |
| 3.0 | 2026-03-31 | Copilot | 5-module split, bus-managed config, WeChat KF sync state |
| 4.0 | 2026-07-30 | Claude | Full sync with codebase: 12 migrations, BindingID, ConfigItems API, ContextualTool, DockerClient interface |
| 5.0 | 2026-08-15 | Claude | Enterprise platform sync: 26 migrations, nanoauth, REST + SSE transport, 70 protocol constants, multi-agent runtime, hypervisor/tunnel, docker/swarm/k8s provisioners, security & audit, updated deployment targets |
