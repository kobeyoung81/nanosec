# NanoSec Deployment Guide

**Version**: 2.0
**Date**: 2026-11-12
**Status**: Current

This guide covers installing and operating the NanoSec stack. It assumes you
already understand the architecture (see [ARCHITECTURE.md](./ARCHITECTURE.md)):
the bus carries messages, and every other domain belongs to the module that owns
it.

## Overview of Deployment Targets

| Target | File | Provisioner backend | Best for |
|--------|------|---------------------|----------|
| Local / single host | `docker-compose.yml` | `docker` | Development, small single-node |
| Docker Swarm | `deploy/swarm/docker-stack.yml` | `swarm` | Medium tier (20–100 users) |
| Kubernetes | `deploy/k8s/*` | `k8s` | Production / large scale |
| CI/CD (build server) | Jenkins job (configured on the server) | `docker` | Automated image builds |

All targets share the same model:

- **One MongoDB database**, named in `NANOSEC_BUS_DATABASE_URI` (the path; `nanosec`
  in the reference deployment). Several services hold a connection to it, and each
  writes **only its own prefix**:

  | Prefix | Writer |
  |--------|--------|
  | `auth_` | `nanoauth` (accounts, channel and OAuth links, refresh tickets, git shortcuts, per-user secrets) |
  | `admin_` | `nanoadmin` (configuration, agent types and their overrides, prompts, models, capabilities, permission keys, alert rules, the audit trail) |
  | `portal_` | `nanoportal` (agents, groups, binding preferences, the session projection) |
  | `provisioner_` | `nanoprovisioner` (container requests, the runner registry) |
  | `bus_` / `sys_` | `nanobus` (its two message queues, the sequence counters, the migration records) |
  | `artifacts` / `artifacts_` | `nanoartifacts` (the work library and its GridFS buckets) |

  Nobody writes another module's prefix. Cross-module reads and writes go over the
  internal HTTP surfaces with `NANOSEC_BUS_INTERNAL_TOKEN`, and those surfaces refuse
  requests when the token is unconfigured.
- **Two one-shot bootstrap containers** run before the services: `admin-init` (its
  manifests and the platform seeds) and `bus-init` (its manifests).
- **Images**: `docker-compose.yml` builds and tags `kobeyoung81/<service>:nanosec`
  locally; the swarm and k8s manifests reference `kobeyoung81/<service>:latest`, so
  those targets need the images available to the cluster (built on the node, or
  pushed to a registry).
- **No JWT key provisioning** — `nanoauth` generates its RS256 keypair on first boot
  and stores it in the platform configuration (`admin_config`, component `auth`,
  keys `jwtPrivateKey`/`jwtPublicKey`), so no key files or secrets are mounted.

## Prerequisites

- Git with SSH access to gitee.com
- Docker 20.10+ and Docker Compose v2 (Compose target)
- `kubectl` (Kubernetes target) or Swarm manager nodes (Swarm target)
- Go 1.25+ only if building from source instead of containers

## 1. Get the Code

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/nanosec.git
cd nanosec

# If you cloned without submodules:
git submodule update --init --recursive
```

The submodules are the services: `nanobus`, `nanoadmin`, `nanoauth`, `nanoportal`,
`nanogateway`, `nanoagent` (the per-user agent runtime), `nanoprovisioner`,
`nanoprotocol` (the shared contract library), `nanoasr` (speech-to-text),
`nanoartifacts` (the work library) and `nanoui` (the Mini Program backend).

Install the pre-commit hooks (optional but recommended — they check that every
module still builds with `GOWORK=off`):

```bash
./scripts/install-hooks.sh
```

## 2. MongoDB

The platform uses **one database**. Create it and a user that can read and write it:

```js
use nanosec
db.createUser({
  user: "nanosec",
  pwd: "<a strong password>",
  roles: [{ role: "readWrite", db: "nanosec" }],
})
```

The URI names that database in its path:

```
mongodb://nanosec:<password>@<host>:27017/nanosec?authSource=admin
```

A **single-node replica set** is enough (`replicaset` + `oplog` are what the future
change-stream work needs; the dev stack runs one member). Add `?replicaSet=rs0` to
the URI when the set has a name.

> The compose stack has no fallback for the URI: `docker-compose.yml` uses
> `${NANOSEC_BUS_DATABASE_URI:?…}` and refuses to start without one.
>
> **Security:** the `nanoauth` RSA private key lives in this database
> (`admin_config`, component `auth`). Restrict access, and treat backups as secrets.

## 3. Docker Compose (single host)

### Start

```bash
cp .env.example .env
# edit NANOSEC_BUS_DATABASE_URI, NANOSEC_BUS_INTERNAL_TOKEN and
# NANOARTIFACTS_SESSION_SECRET (the three values compose refuses to start without)

docker compose up -d
```

`admin-init` runs first — its manifests, then `config seed`, `permissions seed`,
`agent-types seed`, `prompts seed`, `skills seed`, `mcp seed` — because `bus-init`
and the running services read configuration from it. `bus-init` applies the bus's own
manifests. Then `nanobus`, `nanoadmin`, `nanoauth`, `nanogateway`, `nanoportal`,
`nanorunner`, `nanoartifacts` and `nanoasr` start. `nanoauth` generates its JWT
keypair on first boot and writes it through `nanoadmin`.

Verify:

```bash
docker compose ps                        # every service up; the two init containers exited 0
curl -s http://localhost:14403/healthz   # the portal's nginx — 200 when it is serving
curl -s http://localhost:14401/auth/v1/.well-known/jwks | head -c 80   # nanoauth's key set
curl -s -H "Authorization: Bearer $NANOSEC_BUS_INTERNAL_TOKEN" \
  http://localhost:14400/api/v1/runners | head -c 120   # the bus answers only with the token
```

The bus has no anonymous `/healthz`: its REST surface is guarded, and an
unauthenticated probe is refused rather than served. `GET /api/v1/runners` is a cheap
liveness check that also proves its store is reachable.

Build the per-user agent image the provisioner launches (the `nanosec` service is
behind the `agent` profile, so `up` does not start or build it):

```bash
docker compose build nanosec
```

### First administrator

A fresh installation has no administrator, and the console hides every
administrative surface from an ordinary account. The **first account to register**
takes the role: open <http://localhost:14403>, register, and the Admin Panel entry is
there immediately — no second step and no sign-out. The rule runs in `nanoauth`, next
to the account it changes; it is one-shot (an atomic claim) and only fires while no
administrator exists.

It is controlled by `auth.firstUserIsAdmin` (seeded `true`). Turn it off **before**
exposing registration to an untrusted network:

```bash
docker compose exec nanoadmin nanoadmin config set auth firstUserIsAdmin false
```

The bus logs a warning on startup while the installation still has no administrator,
naming this rule. To promote an existing account by hand, set the role and sign in
again — the role travels inside the access token:

```bash
curl -s -X PATCH -H "Authorization: Bearer $NANOSEC_BUS_INTERNAL_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"role":"admin"}' \
  http://localhost:14400/api/v1/user-accounts/<user-id>
```

### First model, first agent

Registering an account also creates its first agent (`My Agent`, type `build`) and
queues a container request, so there is nothing to create by hand.

Adding a provider and a model to the catalogue is not enough on its own: agents
resolve their model through their **agent type**, and a fresh installation has no
bindings. On the Models page use **Apply to built-in types** on the model. It is
fill-only — every built-in type gets the model, and a type with no default model yet
gets it as its default; existing defaults are left alone. Running it again changes
nothing.

Until then an agent cannot start. Its log says so plainly
(`no model is assigned to agent type "build": assign one in the admin console`)
instead of reporting a missing API key. An agent that already failed (the supervisor
stops retrying after a few attempts) needs one restart from the portal once the model
is applied.

### Configure channels and the agent

Operational configuration is the `admin` module's (`admin_config`). Edit it in the
portal (Configs page) or from the CLI:

```bash
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.enabled true
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.userID alice
docker compose exec nanoadmin nanoadmin config set agent provider.apiKey sk-...
docker compose exec nanoadmin nanoadmin config set agent provider.baseUrl https://api.openai.com/v1
docker compose exec nanoadmin nanoadmin config set agent provider.defaultModel gpt-4o
docker compose restart nanogateway   # re-reads its configuration on start
```

Most services re-read their component per request or on a short cache, so an edit
usually takes effect without a restart; the gateway is the exception that is easiest
to restart.

> `nanogateway` exits with "no channels enabled" unless at least one channel is
> enabled. The **web chat channel is enabled by default** (`channels.web.enabled=true`,
> seeded by `admin-init`); it listens on `:8080` inside the compose network (host
> port **14402**) and the portal proxies it under its own origin, so browsers
> normally never use that port.

### Portal chat

The portal's nginx proxies `/ws/agent/` and `/api/v1/` straight to
`nanogateway:8080` (the web channel), and `/api/user/v1/` to its own Go server, which
talks to the bus and to the other modules. The browser therefore has one origin and
no gateway URL to configure.

The gateway validates the bearer JWT against `nanoauth`'s JWKS and lists the caller's
agents through the portal's internal surface (the agent rows are the portal's). Agents
are created and edited in the portal: self-service under `/api/user/v1/agents`,
cross-user in the console.

### Runner registry

`nanoprovisioner` owns the registry now (`provisioner_runners`): it registers itself
on startup, touches its row every minute and marks a stale row (2 minutes without a
heartbeat) offline. The bus still serves the console's view and forwards registration
and removal, and the portal's **Components → runner** detail lists the entries with a
Remove action for pruning dead ones.

### Smoke test

```bash
docker compose run --rm nanogateway --bus-url http://nanobus:9000 --message "Hello"
```

(The CLI channel needs `channels.cli.enabled` and a `userID`; the portal chat is the
shortcut that always works.)

### Update / tear down

```bash
docker compose up -d --build     # rebuild the images from this checkout, recreate
docker compose down              # stop everything
```

> `docker compose down` leaves MongoDB untouched: the database is external to the
> stack. Agent workspaces are volumes the provisioner creates per user; they survive
> a compose teardown and are what to back up.
>
> Recreating only some services is fine, but remember the two init containers: they
> have `restart: "no"` and the services wait for them with
> `service_completed_successfully`, so a plain `up -d` after changing their inputs
> needs `docker compose up -d --force-recreate admin-init bus-init` (or a full
> `down`/`up`) to re-run them.

## 4. Docker Swarm

Stack file: `deploy/swarm/docker-stack.yml` (medium tier, 20–100 users). A stack file
cannot interpolate `.env`, so export the values in the deploying shell first — it
fails fast without them:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
export NANOARTIFACTS_SESSION_SECRET="$(openssl rand -hex 32)"
```

### Steps

1. Bootstrap the store once (from any manager, with MongoDB reachable). The two
   images already carry the CLIs, so this is the same order the compose init
   containers run:

```bash
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest migrate up
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest config seed
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest permissions seed
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest agent-types seed
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest prompts seed
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest skills seed
docker run --rm -e NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest mcp seed
docker run --rm -e NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanobus:latest migrate up
docker run --rm -e NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  kobeyoung81/nanoadmin:latest config set runner backend swarm
```

2. Deploy the stack:

```bash
docker stack deploy -c deploy/swarm/docker-stack.yml nanosec
```

`nanorunner` uses the swarm backend and creates one single-replica service per user
with resource limits. `nanobus`, `nanoauth` and `nanoportal` are constrained to
manager nodes. The stack file names `kobeyoung81/<service>:latest`, so build and tag
the images on the manager (or push them to a registry the nodes can pull from) first.

## 5. Kubernetes

Manifests in `deploy/k8s/`. The provisioner uses the k8s backend.

### Steps

1. Edit `deploy/k8s/02-secrets.yaml`: set `mongo-uri` to your MongoDB and
   `internal-token` to a generated secret. It is the only Secret the stack needs.

2. Create the namespace and the secrets:

```bash
kubectl apply -f deploy/k8s/00-namespace.yaml
kubectl apply -f deploy/k8s/02-secrets.yaml
```

3. Deploy the services:

```bash
kubectl apply -f deploy/k8s/02-nanobus.yaml     # its init Job (manifests), then the Deployment
kubectl apply -f deploy/k8s/03-nanoauth.yaml
kubectl apply -f deploy/k8s/04-services.yaml    # nanoportal + nanogateway
kubectl apply -f deploy/k8s/05-nanorunner.yaml
```

`05-nanorunner.yaml` uses the provisioner's ServiceAccount; the RBAC manifest lives
beside the provisioner's own deploy files:

```bash
kubectl apply -f nanoprovisioner/deploy/k8s/rbac.yaml
```

The k8s manifests predate the admin module's split: they still describe the bus,
auth, gateway, portal and runner, so a cluster deployment needs a `nanoadmin`
Deployment (and its one-shot init Job) added from `deploy/k8s/` before the console's
catalogue pages work. That gap is tracked in the plan; the compose and swarm targets
already carry it.

4. Verify and expose the portal:

```bash
kubectl -n nanosec get pods
kubectl -n nanosec port-forward svc/nanoportal 8080:80
```

## 5.1 Identity keys (admin, artifacts, nginx)

`nanoadmin` and `nanoartifacts` verify browser tokens themselves against
nanoauth's key set. Both read `NANOAUTH_JWKS_URL`, defaulting to
`http://nanoauth:8081/auth/v1/.well-known/jwks` — direct, not through the bus.
The portal's nginx also exposes `/api/auth/v1/*` straight to `nanoauth`
(rewritten to `/auth/v1/*`), so a client that only needs a token does not pass
through the portal's Go server.

## 6. Standalone (no containers)

Run MongoDB yourself, then build and run binaries from the workspace. Every command
that touches the store reads the same `NANOSEC_BUS_DATABASE_URI`:

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"

# Store (the two init containers' steps, in order)
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin migrate up
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanoadmin/cmd/nanoadmin permissions seed
go run ./nanoadmin/cmd/nanoadmin agent-types seed
go run ./nanoadmin/cmd/nanoadmin prompts seed
go run ./nanoadmin/cmd/nanoadmin skills seed
go run ./nanoadmin/cmd/nanoadmin mcp seed

# Bus (messages)
NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanobus/cmd/nanobus

# Admin (configuration and the catalogues)
NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoadmin/cmd/nanoadmin

# Auth (its own collections; writes its JWT keypair into the platform config on
# first boot)
NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoauth/cmd/nanoauth

# Portal (agents, groups, the session projection; its Go server + the built UI)
NANO_PORTAL_BUS_URL="http://localhost:9000" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOPORTAL_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoportal/server/cmd/nanoportal

# Gateway (the CLI channel; configure the channels first)
NANOSEC_GATEWAY_BUS_URL="http://localhost:9000" \
  go run ./nanogateway/cmd/nanogateway

# Provisioner (needs Docker; it is what launches the per-user agent containers)
NANOSEC_PROVISIONER_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoprovisioner/cmd/nanorunner

# Agent (what the provisioner launches, one per user; not normally run by hand)
NANOSEC_PORTAL_URL="http://localhost:14403" \
  go run ./nanoagent/cmd/nanosec --user alice --bus-url http://localhost:9000 --hypervisor-addr :9090
```

## 7. Jenkins CI/CD

The build server runs Jenkins inside a container that mounts the host Docker socket
(`/var/run/docker.sock`), so `docker compose` inside a pipeline talks to the host
daemon. The jobs are configured in Jenkins itself (there is no `Jenkinsfile` in this
repo). Two jobs matter here, and they do different things:

| Job | Repository | Trigger | What it does |
|-----|-----------|---------|--------------|
| `Dev.NanoSec` | `nanosec.git` (this repo) | **none** (no SCM trigger) | `docker compose -p devnanosec build` (and the agent image). It does **not** `up -d`. |
| `Dev.MyriadMind` | `myriadmind-legacy.git` (the previous super-repo) | SCM poll every 2 minutes | Builds and **deploys** the legacy stack (`devmyriadmind`). Unrelated to this repository. |

Consequences, and how the reference deployment is actually released:

- Pushing to this repository builds nothing by itself. The images have to be built
  and the services recreated by hand (or from a job you add):
  `docker build -t kobeyoung81/<service>:nanosec <service>` then
  `docker compose -p <project> --env-file <file> -f docker-compose.yml up -d --no-build <services>`.
- The build server has no anonymous trigger for `Dev.NanoSec` and no auth token for
  it, so a re-run needs a login in the Jenkins UI.
- Two consequences of the socket mount worth knowing:
  1. **Bind-mount sources resolve on the HOST filesystem**. A relative mount like
     `./deploy/keys` is resolved against the Jenkins container's cwd but bound on the
     host, usually pointing at an unrelated directory. The stack avoids relative bind
     mounts; the auth keypair lives in the database, so nothing needs mounting.
  2. **Docker's embedded DNS** resolves `*.home` names to `127.0.0.1` inside compose
     network containers (symptom: `dial tcp 127.0.0.1:27017`). Use the **host LAN IP**
     in `NANOSEC_BUS_DATABASE_URI`.

Environment the stack needs (`.env` for compose, exported for a stack file):

| Variable | Notes |
|----------|-------|
| `NANOSEC_BUS_DATABASE_URI` | The one database; compose fails fast without it |
| `NANOSEC_BUS_INTERNAL_TOKEN` | Shared token every component presents to the internal surfaces |
| `NANOARTIFACTS_SESSION_SECRET` | HMAC key for the work library's preview cookie |

> A `docker compose down` before `up` is the safe order for the init containers:
> `admin-init` and `bus-init` have `restart: "no"`, and the services wait for them
> with `service_completed_successfully`, so an already-exited init container is not
> re-run by a plain `up -d` whose inputs did not change.
>
> Ports already taken by a hand-started container make the deploy fail on the port
> binding — stop those first.

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `admin-init` exits 1 | It runs every seed command by name; a renamed or removed command leaves the old invocation behind | Check its `command` in `docker-compose.yml` against `nanoadmin`'s usage line, and update the **host** compose file too |
| Built-in prompts come up blank on a fresh database | The prompt seeder only writes onto types that already exist | `agent-types seed` must run before `prompts seed` (the init container does this) |
| `nanogateway` exits "no channels enabled" | No channel enabled in the configuration | `nanoadmin config set gateway channels.<name>.enabled true`, restart the gateway |
| Bus can't reach MongoDB | URI unset / wrong host / the path is missing the database name | Set `NANOSEC_BUS_DATABASE_URI` (`…/<database>?authSource=admin`) |
| `dial tcp 127.0.0.1:27017` from a container | Docker's embedded DNS resolves `.home` names to loopback | Put the host LAN IP in the URI |
| `nanoauth` fails to start, "jwt key not readable yet" | The admin module (or its init) is not up | Start `admin-init`/`nanoadmin` first; it retries for about 30 seconds and then fails rather than signing with a key nobody else has |
| Portal fails with "store: mongo uri is required" | `NANOPORTAL_MONGO_URI` not injected | Compose derives it from `NANOSEC_BUS_DATABASE_URI`; set that |
| A service's image build fails at `go mod download` | The module's `go.mod` needs a newer Go than the Dockerfile pins | Bump the Dockerfile to `golang:1.25-alpine` (mongo-driver v2 needs 1.25) |
| The provisioner cannot launch agents | `nanosec` (agent) image not built — it is behind the `agent` profile | `docker compose build nanosec` |
| `migrate up` never completes | MongoDB briefly unreachable during bootstrap | The init containers retry 30×; for a manual bootstrap re-run the command |
| Internal calls answer 401/503 | Missing `NANOSEC_BUS_INTERNAL_TOKEN`, or the target refuses when it is unconfigured | Set the same token on every service |
| An agent logs "no model is assigned to agent type …" | The model catalogue has no binding for the type | Models page → **Apply to built-in types**, then restart the agent |

## Backup & Maintenance

- **Database**: `mongodump` the one database (`nanosec`). It holds every platform
  collection — including the `nanoauth` RSA private key (`admin_config`, component
  `auth`) and the password hashes (`auth_users`) — so backups are secrets.
- **Agent state**: each agent's workspace and session transcript live in its own
  container volume (`nanosec-data-<user-id>`), which the provisioner creates. The
  agent's JSONL file is the authoritative session transcript; the portal's copy is a
  projection for history and can be re-synced from it.
- **JWT keys**: stored in `admin_config` (`auth.jwtPrivateKey` secret,
  `auth.jwtPublicKey`). Deleting those rows forces a fresh keypair on next boot,
  invalidating every issued token.
- **Configuration**: `admin_config` is the single key-value store, one row per
  `(component, key)`, seeded by `nanoadmin config seed`. The seeds only fill gaps, so
  re-running them never overwrites an edit.
- **Migrations**: each module applies its own manifests at startup and records them in
  `sys_migrations` as `<service>:<file>`. `nanoadmin migrate status` and
  `nanobus migrate status` show what has been applied.
