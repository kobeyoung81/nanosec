# NanoSec
An ultra-lightweight personal AI assistant system written in Go, composed of multiple microservices that communicate over a shared WebSocket/REST message bus.

[中文文档](./README.zh-CN.md)

## Architecture Overview

```
channels (CLI / WeCom / Feishu / WeChat KF / web)
      │
      ▼
nanogateway ──HTTP + SSE──► nanobus ◄──HTTP + SSE── nanoagent (one container per user)
                              ▲
      ┌───────────────┬───────┴────────┬──────────────────┬───────────────┐
  nanoauth        nanoadmin        nanoportal       nanoprovisioner   nanoartifacts
  (identity)      (catalogues,     (agents, groups, (containers,      (work library,
                   configuration,   sessions, the    the runner         HTML documents)
                   audit trail)     console)         registry)
```

One MongoDB database holds every collection, with one prefix per owner: `auth_`
(nanoauth), `admin_` (nanoadmin), `portal_` (nanoportal), `provisioner_`
(nanoprovisioner), `bus_`/`sys_` (nanobus) and `artifacts*` (nanoartifacts). A
service writes only its own prefix; everything else is read over the internal HTTP
surfaces with the shared token. The bus carries messages and owns nothing else.

- **nanoprotocol** — shared contract (Go module, not a service): the message envelope, the type constants, and the HTTP/SSE client the services use
- **nanoworkspace** — the agent workspace surface: file listing, previews, uploads and the git panel. It stores nothing; it verifies the caller, asks the portal who owns the agent, and forwards through the container's tunnel. nginx routes `/api/user/v1/files/` and `/api/user/v1/git/` here.
- **nanobus** — messaging: per-user queues, the event stream (SSE), the runner plumbing, and the reverse proxy to `nanoauth`'s JWKS (hypervisor tunnels terminate at the provisioner; the bus keeps a fallback for containers that still dial it)
- **nanogateway** — channel adapters (WeCom / Feishu / WeChat KF / web chat / CLI): identity resolution, inbound and outbound routing, media, JWKS validation for the web channel
- **nanoagent** — the agent runtime (binary `nanosec`, one per user): multi-agent routing, the ReAct loop, LLM providers, tools, sessions, skills, cron, subagents and the hypervisor
- **nanoprovisioner** — container provisioning: the container-request queue, the runner registry, and the Docker / Swarm / Kubernetes backends with per-tier quotas
- **nanoauth** — identity: registration, bcrypt credentials, RS256 tokens and JWKS, refresh tickets, channel and OAuth links, per-user secrets
- **nanoadmin** — the administrative domain: configuration, agent types and their overrides, prompts, models, capabilities, permission keys, alert rules, the audit trail
- **nanoportal** — the console (Go + React): users, agents and groups, conversations, the work library's shell, and the browser chat
- **nanoartifacts** — the work library: published HTML documents, versions, spaces, sharing and storage quotas
- **nanoui** — the WeChat Mini Program and its Go BFF

## Repository Layout

```
nanosec/                       # Super-repo (workspace, docs, configs, deploy)
├── go.work                    # Go workspace (nine modules, local unified builds)
├── docker-compose.yml         # One-command stack (all services + the two init containers)
├── .env.example               # Template for the database URI, the shared token and the library's cookie key
├── .gitmodules                # Submodule registry (eleven submodules)
├── configs/                   # Config shape examples (*.example.json, dev/)
├── docs/                      # Architecture, deployment and design documents
├── scripts/                   # bump-protocol.sh, install-hooks.sh, p1-migrate.sh
├── deploy/                    # Production manifests
│   ├── swarm/                 #   Docker Swarm stack
│   └── k8s/                   #   Kubernetes manifests
├── nanoprotocol/              # [submodule] Shared contract library
├── nanobus/                   # [submodule] Message bus
├── nanogateway/               # [submodule] Channel gateway
├── nanoagent/                 # [submodule] Agent runtime (binary: nanosec)
├── nanoprovisioner/           # [submodule] Container provisioning (binary: nanorunner)
├── nanoadmin/                 # [submodule] Administrative domain (config, catalogues, audit)
├── nanoauth/                  # [submodule] Identity service
├── nanoportal/                # [submodule] Console (Go + React)
├── nanoartifacts/             # [submodule] Work library
└── nanoui/                    # [submodule] WeChat Mini Program + BFF
```

Each service submodule has its own `README.md` with architecture, config and CLI
reference.

## Submodule Configuration

This repository uses Git submodules to manage each service, and a Go workspace
(`go.work`) for local unified builds.

| Submodule path | Remote | What it is |
|----------------|--------|------------|
| `nanoprotocol` | `../nanoprotocol.git` | Shared contract library |
| `nanobus` | `../nanobus.git` | Message bus |
| `nanogateway` | `../nanogateway.git` | Channel gateway |
| `nanoagent` | `../nanoagent.git` | Agent runtime (binary `nanosec`) |
| `nanoprovisioner` | `../nanoprovisioner.git` | Container provisioning (binary `nanorunner`) |
| `nanoadmin` | `git@gitee.com:kobeyoung81/nanoadmin.git` | Administrative domain |
| `nanoauth` | `../nanoauth.git` | Identity service |
| `nanoportal` | `../nanoportal.git` | Console |
| `nanoartifacts` | `../nanoartifacts.git` | Work library |
| `nanoui` | `../nanoui.git` | Mini Program + BFF |

The remote URLs are relative, so they resolve against the super-repo's origin.

### Go Workspace

`go.work` unifies nine modules for local development — no publishing needed to
reference one from another (`nanoui` builds on its own):

```
go 1.26.2

use (
	./nanoportal
	./nanobus
	./nanogateway
	./nanoprotocol
	./nanoprovisioner
	./nanoagent
	./nanoauth
	./nanoartifacts
	./nanoadmin
)

replace github.com/xen0n/go-workwx/v2 v2.0.0-alpha.1 => ./nanogateway/go-workwx
```

Build every module in the workspace:

```bash
go build ./nanobus/... ./nanogateway/... ./nanoagent/... ./nanoprovisioner/... \
         ./nanoadmin/... ./nanoauth/... ./nanoportal/... ./nanoartifacts/...
```

> The pre-commit hook (installed via `./scripts/install-hooks.sh`) verifies each
> submodule also builds standalone with `GOWORK=off`.

## Installation

### Prerequisites

- **Go 1.25+** (the workspace is built with Go 1.26.2; the modules declare their own minimum)
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
> and stores it in the platform configuration (`admin_config`, component `auth`,
> keys `jwtPrivateKey`/`jwtPublicKey`), so there are no key files or secrets to
> generate or mount.

### 2. Provide a MongoDB

The platform uses **one database**. Several services hold a connection to it and
each writes only its own prefix (see the overview above), so the database URI is
the one setting every part of the stack shares. Compose reads it from your shell
environment or a project `.env` file:

```bash
cp .env.example .env    # then edit NANOSEC_BUS_DATABASE_URI=...
```

or export the required values:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
export NANOARTIFACTS_SESSION_SECRET="$(openssl rand -hex 32)"
```

The URI must name the database in its path (`/nanosec` above); a single-node
replica set is enough. None of the three has a fallback in `docker-compose.yml`
(`:?`), so the stack refuses to start without them — that is the intended reminder.

### 3. Start the stack

```bash
docker compose up -d
```

This starts:

| Service | Host port | Purpose |
|---------|-----------|---------|
| `nanobus` | 14400 → 9000 | Messaging: REST, SSE, the tunnel fallback, the JWKS proxy |
| `nanoauth` | 14401 → 8081 | Identity: registration, tokens, JWKS |
| `nanogateway` | 14402 → 8080 | Channel adapters; the web chat channel is proxied same-origin by the portal |
| `nanoportal` | 14403 → 80 | The console (and, through its nginx, the gateway's web channel and the work library) |
| `nanoadmin` | 14404 → 8080 | Configuration and the catalogues |
| `nanoartifacts` | – | Work library (reached through the portal's `/nanoartifacts/`) |
| `nanorunner` | – | Container provisioning and hypervisor tunnels (needs the host's `docker.sock`) |
| `nanoworkspace` | – | File browser, previews and the git panel; routes to the agent's tunnel |

`admin-init` runs first (its manifests, then the `config`, `permissions`,
`agent-types`, `prompts`, `skills` and `mcp` seeds), then `bus-init` (its own
manifests), then the services. The agent image is **not** started by `up`: it is
what the provisioner launches per user, and it sits behind the `agent` profile.
Build it with:

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
docker compose exec nanoadmin nanoadmin config get gateway
docker compose exec nanoadmin nanoadmin config get agent
```

> `nanogateway` exits with "no channels enabled" unless at least one channel is
> enabled in the configuration. The **web chat channel is enabled by default**
> (`channels.web.enabled=true`, seeded by `nanoadmin config seed`) and listens on
> `8080` inside the compose network, published on host port `14402`; the portal also
> proxies it same-origin for its Chat page.

### 5. Try it

Open the portal at **http://localhost:14403** and register: the first account of a
fresh installation becomes its administrator, gets a default agent and a container
request, so **Chat** is usable as soon as the container is up. Alternatively, chat
through the CLI channel:

```bash
# the gateway with only the CLI channel sends one message and exits
docker compose run --rm nanogateway --bus-url http://nanobus:9000 --message "Hello"
```

### Standalone (no Docker)

Run MongoDB yourself, then build and run each binary from the workspace. Every
command that touches the store takes the same `NANOSEC_BUS_DATABASE_URI`:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"

# 1. Apply the manifests (what the two init containers do, in order)
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin migrate up

# 2. Seed the platform defaults and catalogues (admin-init runs all of these)
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanoadmin/cmd/nanoadmin permissions seed
go run ./nanoadmin/cmd/nanoadmin agent-types seed
go run ./nanoadmin/cmd/nanoadmin prompts seed
go run ./nanoadmin/cmd/nanoadmin skills seed
go run ./nanoadmin/cmd/nanoadmin mcp seed

# 3. The bus (messages)
go run ./nanobus/cmd/nanobus

# 4. The admin domain (configuration and catalogues)
NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoadmin/cmd/nanoadmin

# 5. Identity (its own collections; writes its JWT keypair into the platform config)
NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoauth/cmd/nanoauth

# 6. The console (agents, groups, the session projection, the UI)
NANO_PORTAL_BUS_URL="http://localhost:9000" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOPORTAL_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoportal/server/cmd/nanoportal

# 7. A gateway (the CLI channel; enable it first)
NANOSEC_GATEWAY_BUS_URL="http://localhost:9000" \
  go run ./nanogateway/cmd/nanogateway

# 8. The provisioner (needs Docker; it launches the per-user agent containers)
NANOSEC_PROVISIONER_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoprovisioner/cmd/nanorunner
```

The agent itself is what step 8 launches, one container per user
(`nanosec --user <id> --bus-url …`). See
[docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md) for the full sequence.

## Production Deployments

See [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md) for full operations guidance, including:

- **Docker Compose** (single host) — this README
- **Docker Swarm** — `deploy/swarm/docker-stack.yml` (`runner.backend=swarm`)
- **Kubernetes** — `deploy/k8s/*` (`runner.backend=k8s`, RBAC in `nanoprovisioner/deploy/k8s`)

## Config Environment Variable Prefixes

Environment variables cover connection-level settings; the operational settings
live in `admin_config` and are edited in the console (or with
`nanoadmin config set`).

| Service | Prefix | Examples |
|---------|--------|----------|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_DATABASE_URI`, `NANOSEC_BUS_INTERNAL_TOKEN`, `NANOSEC_BUS_ADMIN_BASE_URL`, `NANOSEC_BUS_PORTAL_BASE_URL`, `NANOSEC_BUS_PROVISIONER_BASE_URL` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL`, `NANOSEC_ADMIN_URL`, `NANOSEC_PORTAL_URL` |
| `nanoagent` | `NANOSEC_` / `NANOSEC_AGENT_` | `NANOSEC_AGENT_BUS_URL`, `NANOSEC_ADMIN_URL`, `NANOSEC_PORTAL_URL` |
| `nanoprovisioner` | `NANOSEC_RUNNER_` / `NANOSEC_PROVISIONER_` | `NANOSEC_RUNNER_BUS_URL`, `NANOSEC_RUNNER_BACKEND`, `NANOSEC_PROVISIONER_MONGO_URI`, `NANOSEC_PROVISIONER_ADDR` |
| `nanoadmin` | `NANOSEC_ADMIN_` | `NANOSEC_ADMIN_MONGO_URI`, `NANOSEC_ADMIN_ADDR`, `NANOSEC_BUS_URL` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_MONGO_URI`, `NANOAUTH_ADDR`, `NANOAUTH_JWT_KEY_ID`, `NANOAUTH_WECHAT_APP_ID` |
| `nanoportal` | `NANO_PORTAL_` / `NANOPORTAL_` | `NANO_PORTAL_BUS_URL`, `NANOPORTAL_MONGO_URI`, `NANOSEC_ADMIN_URL` |
| `nanoartifacts` | `NANOARTIFACTS_` | `NANOARTIFACTS_MONGO_URI`, `NANOARTIFACTS_SESSION_SECRET`, `NANOARTIFACTS_QUOTA_BYTES` |
| `nanoui` (backend) | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR` |

> `NANOSEC_BUS_INTERNAL_TOKEN` is the platform-wide shared secret: every internal
> surface (`/internal/v1/*`) answers only requests that carry it, and refuses when it
> is unconfigured. `NANOSEC_ADMIN_URL` is where a service finds its own configuration.

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
