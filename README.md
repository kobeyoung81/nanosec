# NanoSec
An ultra-lightweight personal AI assistant system written in Go, composed of multiple microservices that communicate over a shared WebSocket/REST message bus.

[中文文档](./README.zh-CN.md)

## Architecture Overview

```
User / Chat Platform
        │
        ▼
┌─────────────────┐   WebSocket   ┌──────────────┐   WebSocket   ┌──────────────┐
│  nanogateway    │ ◄────────────► │   nanobus    │ ◄────────────► │   nanosec    │
│ (gateway svc)   │               │ (message bus) │               │ (AI agent)   │
└─────────────────┘               └──────────────┘               └──────────────┘
                                          │  ▲            │  ▲
                    ┌─────────────────────┘  │            │  │ HTTP (hypervisor :9090)
                    ▼                        │            │  │ WebSocket tunnel
                MongoDB             ┌─────────────────┐   │
                                    │  nanorunner     │───┘──► Docker / Swarm / K8s
                                    │ (container svc) │
                                    └─────────────────┘

  Auth:   nanoauth (OAuth2/OIDC, JWT) ── proxied by nanobus ──► portal / gateway / miniapp
  Admin:  nanoportal (React admin UI) ── reads/writes the bus (no database of its own)
  Mobile: nanoui (WeChat Mini Program + Go BFF)
```

- **nanoprotocol** — Shared wire protocol (Go module, not a service): message envelope, 70 type constants, WebSocket client with auto-reconnect, REST/SSE helpers
- **nanobus** — message broker (WebSocket + REST + SSE): per-user message queues, runner registry and the platform's event stream. Configuration and the admin catalogues live in **nanoadmin**; the bus asks for what it needs over HTTP
- **nanogateway** — Chat platform adapters (WeCom / Feishu / WeChat KF / Web Chat / CLI); routes inbound/outbound messages, sends ack on receipt, routes media attachments, validates JWTs for the web channel
- **nanosec** — AI agent runtime; multi-agent router, ReAct loop, LLM providers, tools, sessions, skills, cron, subagents, and a hypervisor HTTP server
- **nanorunner** — Container provisioning service; polls the bus for container requests and provisions/disposes per-user agents via Docker, Swarm, or Kubernetes backends with per-tier quotas
- **nanoauth** — OAuth2/OIDC authentication service: registration, bcrypt passwords, RS256 JWTs, JWKS endpoint, refresh tokens, WeChat Mini Program login
- **nanoportal** — Web management portal (Go + React) for user/agent/config/audit administration and browser chat
- **nanoui** — Web UI with WeChat Mini Program frontend + Go backend (BFF)

## Repository Layout

```
nanosec/                       # Super-repo (workspace, docs, configs, deploy)
├── go.work                    # Go workspace (7 modules, local unified builds)
├── docker-compose.yml         # One-command stack (bus + auth + gateway + runner + portal)
├── .env.example               # Template for the bus's Mongo URI + shared token (copy to .env)
├── .gitmodules                # Submodule registry (8 services)
├── configs/                   # Config shape examples (*.example.json, dev/)
├── docs/                      # Architecture, PRD, deployment, design docs
├── plans/                     # Implementation plans
├── scripts/                   # bump-protocol.sh, install-hooks.sh
├── deploy/                    # Production manifests
│   ├── swarm/                 #   Docker Swarm stack
│   └── k8s/                   #   Kubernetes manifests
├── nanoprotocol/              # [submodule] Shared protocol library
├── nanobus/                   # [submodule] Message bus service
├── nanogateway/               # [submodule] Gateway service
├── nanosec/                   # [submodule] AI agent service
├── nanorunner/                # [submodule] Container provisioning service
├── nanoauth/                  # [submodule] OAuth2/OIDC auth service
├── nanoportal/                # [submodule] Web management portal
└── nanoui/                    # [submodule] Web UI + WeChat Mini Program
```

Each service submodule has its own `README.md` with architecture, config, and CLI reference.

## Submodule Configuration

This repository uses Git submodules to manage each service, and a Go workspace (`go.work`) for local unified builds.

### Git Submodules

| Submodule path | Remote (SSH) | Description |
|----------------|--------------|-------------|
| `nanoprotocol` | `git@gitee.com:kobeyoung81/nanoprotocol.git` | Shared protocol library |
| `nanobus` | `git@gitee.com:kobeyoung81/nanobus.git` | Message bus service |
| `nanogateway` | `git@gitee.com:kobeyoung81/nanogateway.git` | Gateway service |
| `nanosec` | `git@gitee.com:kobeyoung81/nanosec.git` | AI agent service |
| `nanorunner` | `git@gitee.com:kobeyoung81/nanorunner.git` | Container provisioning |
| `nanoauth` | `git@gitee.com:kobeyoung81/nanoauth.git` | OAuth2/OIDC auth service |
| `nanoportal` | `git@gitee.com:kobeyoung81/nanoportal.git` | Web management portal |
| `nanoui` | `git@gitee.com:kobeyoung81/nanoui.git` | Web UI + WeChat miniapp |

### Go Workspace

`go.work` unifies the seven Go modules for local development — no publishing required to reference one from another:

```
go 1.26.2

use (
    ./nanoportal
    ./nanobus
    ./nanogateway
    ./nanoprotocol
    ./nanorunner
    ./nanosec
    ./nanoauth
)

replace github.com/xen0n/go-workwx/v2 v2.0.0-alpha.1 => ./nanogateway/go-workwx
```

Build all services:

```bash
go build ./nanobus/... ./nanogateway/... ./nanosec/... ./nanorunner/... ./nanoauth/... ./nanoportal/...
```

> The pre-commit hook (installed via `./scripts/install-hooks.sh`) verifies each
> submodule also builds standalone with `GOWORK=off`.

## Installation

### Prerequisites

- **Go 1.25+** (the workspace is built with Go 1.26.2; most modules declare `go 1.24`, the bus declares `go 1.25`)
- **Git** with SSH access to gitee.com (`git@gitee.com:kobeyoung81/...`)
- **Docker + Docker Compose v2** (for the containerized stack)
- Optional: `kubectl` / Swarm manager for Kubernetes / Swarm deployments

### 1. Clone the repository (with all submodules)

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/nanosec.git
cd nanosec
```

If you already cloned without submodules, initialize them:

```bash
git submodule update --init --recursive
```

Install the pre-commit hooks for all submodules (verifies standalone builds):

```bash
./scripts/install-hooks.sh
```

> **No JWT key setup needed.** `nanoauth` generates its RSA keypair on first boot
> and stores it behind the bus (`service_config_items`, component `auth`, keys
> `jwtPrivateKey`/`jwtPublicKey`), so there are no key files or secrets to
> generate or mount.

### 2. Provide a MongoDB

The platform has one store: a MongoDB database owned by `nanobus`. Every other
service reaches it through the bus, so the bus's URI is the only database
setting in the stack. Compose reads it from your shell environment or a project
`.env` file:

```bash
cp .env.example .env    # then edit NANOSEC_BUS_DATABASE_URI=...
```

or export both required values:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanobus?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
```

> Neither value has a fallback in `docker-compose.yml` (`:?`), so the stack refuses
> to start without them — that is the intended reminder to set them.

The URI must name the database the bus owns (`/nanobus` above). Point it at a
local server (`127.0.0.1`, or `host.docker.internal` when the server runs on the
Docker host) for a single-machine install.

### 3. Start the stack

```bash
docker compose up -d
```

This starts:

| Service | Port | Purpose |
|---------|------|---------|
| `nanobus` | 9000 | Message bus (WS + REST + SSE + auth proxy) |
| `nanoauth` | 8081 | OAuth2/OIDC auth |
| `nanorunner` | – | Container provisioning (needs host `docker.sock`) |
| `nanogateway` | 18080 → 8080 | Chat platform adapters + web chat channel (proxied same-origin by the portal) |
| `nanoportal` | 28080 → 80 | Admin web UI |

`bus-init` runs first: it applies the collection manifests and seeds the built-in
catalogs, then the bus starts. The `nanosec` agent image is **not** started by `up`;
it is the image nanorunner uses to provision per-user agent containers. Build it with:

```bash
docker compose build nanosec
```

### 4. Configure channels and the agent

Services load their configuration at startup from the admin module (`admin_config`, served over HTTP),
seeded by `nanoadmin config seed`; the built-in catalogs (skills, prompts,
agent types, MCP servers, permission keys) are `nanoadmin`'s too, and the
`admin-init` container seeds them on every start. Edit them in the portal, or
with the CLI:

```bash
# Enable the CLI channel (quick smoke test)
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.enabled true
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.userID alice

# Set the LLM API key for the agent
docker compose exec nanoadmin nanoadmin config set agent provider.apiKey sk-...
docker compose exec nanoadmin nanoadmin config set agent provider.baseUrl https://api.openai.com/v1
docker compose exec nanoadmin nanoadmin config set agent provider.defaultModel gpt-4o

# Check current values
docker compose exec nanobus nanobus config get gateway
docker compose exec nanobus nanobus config get agent
```

> `nanogateway` exits with "no channels enabled" unless at least one channel is
> enabled in the bus config. The **web chat channel is enabled by default**
> (`channels.web.enabled=true`, seeded by `nanoadmin config seed`) and listens on
> `8080` inside the compose network, published on host port `18080`; the portal also
> proxies it same-origin for its Chat page.

### 5. Try it

Open the portal at **http://localhost:28080** (nanoportal's published port) and open
**Chat** to create agents and talk to them. Alternatively, chat via the CLI channel:

```bash
# gateway with only the CLI channel sends one message and exits
docker compose run --rm nanogateway --bus-url ws://nanobus:9000 --message "Hello"
```

### Standalone (no Docker)

Run MongoDB yourself, then build and run each binary from the workspace. Every
command that touches the store takes the same `NANOSEC_BUS_DATABASE_URI`:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanobus?authSource=admin"

# 1. Apply the collection manifests (the `bus-init` and `admin-init` steps, in order)
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin migrate up

# 2. Seed the built-in catalogs (admin-init runs all of these)
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanoadmin/cmd/nanoadmin permissions seed
go run ./nanoadmin/cmd/nanoadmin agent-types seed
go run ./nanoadmin/cmd/nanoadmin prompts seed
go run ./nanoadmin/cmd/nanoadmin skills seed
go run ./nanoadmin/cmd/nanoadmin mcp seed

# 3. Start the bus
go run ./nanobus/cmd/nanobus

# 4. In another terminal, start an agent for a user
go run ./nanosec/cmd/nanosec --user alice --bus-url ws://localhost:9000 --hypervisor-addr :9090

# 5. Start the gateway (CLI channel)
go run ./nanogateway/cmd/nanogateway --bus-url ws://localhost:9000
```

## Production Deployments

See [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md) for full operations guidance, including:

- **Docker Compose** (single host) — this README
- **Docker Swarm** — `deploy/swarm/docker-stack.yml` (`runner.backend=swarm`)
- **Kubernetes** — `deploy/k8s/*` (`runner.backend=k8s`, RBAC in `nanorunner/deploy/k8s`)

## Config Environment Variable Prefixes

| Service | Prefix | Example |
|---------|--------|---------|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_DATABASE_URI=mongodb://…` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL=...` |
| `nanosec` | `NANOSEC_` | `NANOSEC_OPENAI_API_KEY=...` |
| `nanorunner` | `NANOSEC_RUNNER_` | `NANOSEC_RUNNER_BUS_URL=...` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_ADDR=:8081` |
| `nanoportal` | `NANO_PORTAL_` | `NANO_PORTAL_BUS_URL=http://nanobus:9000` |
| `nanoui` (backend) | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR=:8088` |

> Gateway, agent, and runner load their operational config from the bus config items
> at runtime; the environment variables above cover connection-level settings.
> `NANOSEC_BUS_` covers the bus's own connection to MongoDB; every other service
> reaches the bus over HTTP with `NANOSEC_BUS_INTERNAL_TOKEN`.

## Protocol Change Workflow

When changing nanoprotocol (new types, constants, or changed signatures), follow this
workflow:

1. Commit the changes to nanoprotocol
2. Run `./scripts/bump-protocol.sh vX.Y.Z` to tag and update all consumers
3. Commit go.mod/go.sum in each consumer submodule
4. Push all submodules before pushing the super-repo

## Contributing

1. Fork this repository
2. Create a `feat/xxx` branch
3. Commit your changes
4. Open a Pull Request
