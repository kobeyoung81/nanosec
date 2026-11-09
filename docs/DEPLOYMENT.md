# MyriadMind Deployment Guide

**Version**: 1.2
**Date**: 2026-10-18
**Status**: Current

This guide covers installing and operating the MyriadMind stack. It assumes you
already understand the architecture (see [ARCHITECTURE.md](./ARCHITECTURE.md)).

## Overview of Deployment Targets

| Target | File | Provisioner backend | Best for |
|--------|------|---------------------|----------|
| Local / single host | `docker-compose.yml` | `docker` | Development, small single-node |
| Docker Swarm | `deploy/swarm/docker-stack.yml` | `swarm` | Medium tier (20–100 users) |
| Kubernetes | `deploy/k8s/*` | `k8s` | Production / large scale |
| CI/CD (build server) | Jenkins job (configured on the server) | `docker` | Automated deployments |

All targets share the same model:

- **One MongoDB database**, named in the bus's URI, owned by `nanobus`. It is the
  only service that holds a database connection; everything else asks the bus over
  HTTP with `NANOSEC_BUS_INTERNAL_TOKEN`.
- Store bootstrap via `nanobus migrate up` (the collection manifests in
  `nanobus/migrations-mongo/`) and the seed commands (`config`, `skills`, `prompts`,
  `permissions`, `agent-types`).
- Prebuilt images: `kobeyoung81/{nanobus,nanogateway,nanosec,nanorunner,nanoauth,nanoportal}:latest`
- **No JWT key provisioning** — `nanoauth` generates its RS256 keypair on first boot
  and stores it behind the bus (`service_config_items`, component `auth`, keys
  `jwtPrivateKey`/`jwtPublicKey`), so no key files/secrets are mounted.

## Prerequisites

- Git with SSH access to gitee.com
- Docker 20.10+ and Docker Compose v2 (Compose target)
- `kubectl` (Kubernetes target) or Swarm manager nodes (Swarm target)
- Go 1.25+ only if building from source instead of using images (the bus's module
  needs it; the images themselves pin the toolchain)

## 1. Get the Code

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/myriadmind.git
cd myriadmind

# If you cloned without submodules:
git submodule update --init --recursive
```

> **Troubleshooting:** if the `nanoauth` submodule fails to clone, your checkout has
> an old `.gitmodules` with an invalid URL. Run `git submodule sync nanoauth` (the
> registered URL should be `git@gitee.com:kobeyoung81/nanoauth.git`) and retry.

Install the pre-commit hooks (optional but recommended):

```bash
./scripts/install-hooks.sh
```

## 2. MongoDB

The whole platform stores everything in **one MongoDB database** owned by the bus.
Create the database and a user that can read and write it:

```js
use nanobus
db.createUser({
  user: "nanosec",
  pwd: "<a strong password>",
  roles: [{ role: "readWrite", db: "nanobus" }],
})
```

The bus connects with a URI of this shape — the path must name the database it owns:

```
mongodb://nanosec:<password>@<host>:27017/nanobus?authSource=admin
```

> The compose stack has no fallback for that URI: `docker-compose.yml` uses
> `${NANOSEC_BUS_DATABASE_URI:?…}` and refuses to start without one.
>
> **Security:** the nanoauth RSA private key is stored in this database
> (`service_config_items.auth.jwtPrivateKey`). Restrict access to the bus, and
> treat backups as secrets.

## 3. Docker Compose (single host)

### Start

```bash
# Fill in the bus's Mongo URI and the shared internal token:
cp .env.example .env        # then edit NANOSEC_BUS_DATABASE_URI=... and NANOSEC_BUS_INTERNAL_TOKEN=...
# OR export both in the shell.

docker compose up -d
```

> Both values are required without a fallback, so the stack fails fast and tells you
> which one is missing — that is the intended reminder to set them.

`bus-init` runs first (applies the collection manifests, seeds the built-in
catalogs), then the bus, auth, runner, gateway, and portal start. `nanoauth`
generates its JWT keypair on first boot and stores it through the bus. Verify:

```bash
docker compose ps                     # bus, auth, runner, gateway, portal all up
curl -s http://localhost:28080/healthz   # the portal's nginx — 200 when it is serving
curl -s -H "Authorization: Bearer $NANOSEC_BUS_INTERNAL_TOKEN" \
  http://localhost:9000/api/v1/config | head -c 120   # the bus answers only with the token
```

> The bus has no `/healthz` of its own: its REST surface is guarded by the shared
> token, and an unauthenticated probe is refused rather than served. `GET
> /api/v1/config` is the cheap liveness check that also proves the store is reachable.

Build the per-user agent image used by the runner:

```bash
docker compose build nanosec
```

### First administrator

A fresh installation has no administrator, and the console hides every
administrative surface from a normal account. The **first account to register**
in the portal takes the role: open <http://localhost:28080>, register, and the
Admin Panel button is there immediately — no second step and no sign-out.

The rule is one-shot per installation and only fires while no administrator
exists. It is controlled by `auth.firstUserIsAdmin` (seeded `true`):

```bash
docker compose exec nanobus nanobus config set auth firstUserIsAdmin false
```

Turn it off **before** exposing registration to an untrusted network. The bus
also logs a warning on startup while the installation still has no
administrator, naming this rule.

To make an existing account an administrator by hand (an installation created
before this rule, or one that opted out), set the role and sign in again — the
role travels inside the access token:

```bash
curl -s -X PATCH -H "Authorization: Bearer $NANOSEC_BUS_INTERNAL_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"role":"admin"}' \
  http://localhost:9000/api/v1/user-accounts/<user-id>
```

### First model

Adding a provider and a model to the catalog is not enough on its own: agents
resolve their model through their **agent type**, and a fresh installation has
no bindings. On the Models page, use **Apply to built-in types** on the model.
It is fill-only — every built-in type gets the model, and a type with no default
model yet gets it as its default; existing defaults are left alone. Running it
again changes nothing.

Until then an agent cannot start. Its log says so plainly
(`no model is assigned to agent type "build": assign one in the admin console`)
instead of reporting a missing API key. An agent that already failed (the
supervisor stops retrying after a few attempts) needs one restart from the
portal once the model is applied.

### Configure Channels & the Agent

Operational config lives behind the bus (`service_config_items`). Edit it via the portal
at **http://localhost:28080** (Configs page) or via the CLI:

```bash
docker compose exec nanobus nanobus config set gateway channels.cli.enabled true
docker compose exec nanobus nanobus config set gateway channels.cli.userID alice
docker compose exec nanobus nanobus config set agent provider.apiKey sk-...
docker compose exec nanobus nanobus config set agent provider.baseUrl https://api.openai.com/v1
docker compose exec nanobus nanobus config set agent provider.defaultModel gpt-4o
docker compose restart nanogateway   # re-reads config
```

> `nanogateway` exits with "no channels enabled" unless at least one channel is enabled.
> The **web chat channel is enabled by default** (`channels.web.enabled=true`, seeded by
> `nanoadmin config seed`). It listens on `:8080` inside the compose network and is
> published on host port **18080**; the portal also proxies it under its own origin,
> so browsers normally never need that port.

### Portal Chat

The Chat page reaches the **nanogateway web channel** through the portal's nginx,
which proxies `/` and `/ws/` to `nanogateway:8080` (same origin — no separate gateway
URL to configure in the compose stack). The gateway itself:
- `GET /api/v1/agents` — validates the bearer JWT (`validate_token` → nanoauth) and
  lists the caller's agents (`list_agents`).
- `GET /ws/chat/{agentID}` — streams chat chunks to the browser.

Agents are managed from the portal (Chat sidebar, My account, or Users & Agents → a
user): create/edit/delete proxies through `POST/PUT/DELETE /api/user/v1/agents`
(self-service, owner-or-operator) and `/api/admin/v1/users/{userID}/agents` for
cross-user views.

### Runner registry

`nanorunner` runs with a stable identity (`--runner-id nanorunner` in compose), so
image updates update the same `runners` document instead of inserting a new one. The bus
marks runners offline when their heartbeat goes stale (2 min) and exposes
`DELETE /api/v1/runners/{id}`; the portal's **Components → nanorunner** detail lists
runners with a Remove action for pruning dead entries.

### Smoke Test

```bash
docker compose run --rm nanogateway --bus-url ws://nanobus:9000 --message "Hello"
```

### Update / Tear Down

```bash
docker compose pull           # fetch latest images
docker compose up -d          # recreate changed services

docker compose down           # stop everything
docker compose down -v        # stop and drop anonymous volumes
```

> `docker compose down` leaves your MongoDB untouched: the database is external to the
> stack, and the only volume the compose file used to declare (a bundled MySQL) is gone.

## 4. Docker Swarm

Stack file: `deploy/swarm/docker-stack.yml` (medium tier, 20–100 users).

A swarm stack file cannot interpolate from `.env`, so export both values in the
deploying shell first — the stack file fails fast without them:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanobus?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
```

### Steps

1. Bootstrap the store once (from any manager, with MongoDB reachable):

```bash
docker run --rm -e NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanobus:latest migrate up
docker run --rm -e NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanobus:latest config seed
docker run --rm -e NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanobus:latest config set runner backend swarm
```

2. Deploy the stack:

```bash
docker stack deploy -c deploy/swarm/docker-stack.yml myriadmind
```

`nanorunner` uses the swarm backend and creates one single-replica service per user
with resource limits. `nanobus`, `nanoauth`, and `nanoportal` are constrained to manager nodes.

## 5. Kubernetes

Manifests in `deploy/k8s/`. The runner uses the k8s provisioner backend.

### Steps

1. Edit `deploy/k8s/02-secrets.yaml`: set `mongo-uri` to your MongoDB and
   `internal-token` to a generated secret. It is the only Secret the stack needs —
   `nanosec-db` (the old MySQL DSN) is gone with the MySQL instance.

2. Create the namespace and the secrets:

```bash
kubectl apply -f deploy/k8s/00-namespace.yaml
kubectl apply -f deploy/k8s/02-secrets.yaml
```

3. Deploy the services:

```bash
kubectl apply -f deploy/k8s/02-nanobus.yaml   # runs the init Job (manifests + seed), then the Deployment
kubectl apply -f deploy/k8s/03-nanoauth.yaml
kubectl apply -f deploy/k8s/04-services.yaml  # nanoportal + nanogateway
kubectl apply -f deploy/k8s/05-nanorunner.yaml
```

`05-nanorunner.yaml` uses the `nanorunner` ServiceAccount; the RBAC manifest lives at
`nanorunner/deploy/k8s/rbac.yaml`:

```bash
kubectl apply -f nanorunner/deploy/k8s/rbac.yaml
```

4. Verify and expose the portal:

```bash
kubectl -n myriadmind get pods
kubectl -n myriadmind port-forward svc/nanoportal 8080:80
```

## 6. Standalone (no containers)

Run MongoDB yourself, then build and run binaries from the workspace. Every command
that touches the store reads the same `NANOSEC_BUS_DATABASE_URI`:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanobus?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"

# Store (the bus-init steps, in order)
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanobus/cmd/nanobus skills seed
go run ./nanobus/cmd/nanobus permissions seed
go run ./nanobus/cmd/nanobus agent-types seed
go run ./nanobus/cmd/nanobus prompts seed

# Bus
NANOSEC_BUS_NANOAUTH_BASE_URL="http://localhost:8081" \
  go run ./nanobus/cmd/nanobus

# Auth (separate terminal; holds no database credentials of its own, and generates
# its JWT keypair into the platform config on first boot)
NANOAUTH_BUS_URL="http://localhost:9000" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoauth/cmd/nanoauth

# Agent (per user, separate terminal)
go run ./nanosec/cmd/nanosec --user alice --bus-url ws://localhost:9000 --hypervisor-addr :9090

# Gateway (CLI channel; configure bus config items first)
go run ./nanogateway/cmd/nanogateway --bus-url ws://localhost:9000

# Runner (optional; needs Docker)
go run ./nanorunner/cmd/nanorunner --bus-url ws://localhost:9000

# Portal (reads everything through the bus)
NANO_PORTAL_BUS_URL="http://localhost:9000" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoportal/server/cmd/nanoportal
```

## 7. Jenkins CI/CD

The build server runs Jenkins inside a container that mounts the **host** Docker
socket (`/var/run/docker.sock`), so `docker compose` inside the pipeline talks to
the host daemon. The job is configured in Jenkins itself (there is no `Jenkinsfile`
in this repo) and polls the super-repo; a push that moves a submodule pointer is what
triggers a deployment.

This has two consequences:

1. **Bind-mount sources resolve on the HOST filesystem**, not inside the jenkins
   container. A relative mount like `./deploy/keys` is interpreted relative to the
   jenkins container's cwd, but the daemon binds the resulting absolute path on the
   *host* — usually pointing at an unrelated directory. The stack avoids relative
   bind mounts; `nanoauth` keys live in the database, so nothing needs to be mounted.
2. **Docker's embedded DNS** resolves `*.home` names to `127.0.0.1` inside compose
   network containers (symptom: `dial tcp 127.0.0.1:27017`). Use the **host LAN IP**
   in `NANOSEC_BUS_DATABASE_URI`.

Environment written into the workspace `.env` before each build:

| Variable | Notes |
|----------|-------|
| `NANOSEC_BUS_DATABASE_URI` | The bus's MongoDB; the compose file fails fast without it |
| `NANOSEC_BUS_INTERNAL_TOKEN` | Shared token every component presents to the bus |

Pipeline steps: checkout → `git submodule update --init --recursive` → write `.env`
→ `docker compose build` (+ `docker compose build nanosec`) → `docker compose down
--remove-orphans` → `docker compose up -d` → `docker image prune -f`.

> `docker compose down` before `up` is **required**: `bus-init` has `restart: "no"`
> and `nanobus` depends on it with `service_completed_successfully`. A plain `up -d`
> never re-runs an exited-failed `bus-init` whose config is unchanged, leaving the
> stack stuck.
>
> Ports already taken by a hand-started container (for instance a cutover bus on
> `:9000`) make the deploy fail on the port binding — stop those first.

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `git submodule update` fails for `nanoauth` | Old `.gitmodules` URL (`./nanoauth`) | `git submodule sync nanoauth`, then retry |
| `nanogateway` exits "no channels enabled" | No channel enabled in bus config | `nanobus config set gateway channels.<name>.enabled true`, restart gateway |
| Bus can't reach MongoDB | `NANOSEC_BUS_DATABASE_URI` unset / wrong host / URI missing the database name | Set it in `.env` or export it before `docker compose up` (see §3) |
| `dial tcp 127.0.0.1:27017` from a container | Docker embedded DNS resolves `.home` names to loopback | Put the host LAN IP (e.g. `<host-lan-ip>`) in the URI |
| `auth.jwtPrivateKey` missing / `nanoauth` fails to start | Store manifests not applied | Run `nanobus migrate up` (or let `bus-init` complete) before starting `nanoauth` |
| Runner can't provision agents | `nanosec:latest` image not built | `docker compose build nanosec` |
| Portal pages report a bus error | `NANO_PORTAL_BUS_URL` unset or bus unreachable | Fix the bus URL/token; the portal reports the failure instead of falling back to sample data |
| WeCom callback unreachable | Callback address inside container not reachable from the internet | Set `channels.wecom.callbackAddr` and expose the gateway port / reverse-proxy the callback |
| `migrate up` never completes | MongoDB briefly unreachable during bootstrap | `bus-init` retries 30×; for manual bootstrap re-run `nanobus migrate up` |

## Backup & Maintenance

- **Database**: `mongodump` the database the bus owns (`nanobus`) — it holds every
  platform collection. The dump **contains the nanoauth RSA private key**
  (`service_config_items.auth.jwtPrivateKey`) — treat backups as secrets.
- **Agent state**: each agent's workspace/sessions live in container volumes
  (`{dataRoot}/agents/{agentID}`) — persist these volumes to keep user data. The
  authoritative session transcript is the agent's own JSONL file; the bus's copy
  exists for history/portal display and is repaired by re-sync when it drifts.
- **JWT keys**: stored in `service_config_items.auth.jwtPrivateKey` / `auth.jwtPublicKey`.
  Deleting the config rows forces a fresh keypair on next boot, invalidating
  all issued tokens — protect them and their backups.
- **Config**: runtime config is in `service_config_items`; the seeded defaults
  live in the `nanobus` binary.
