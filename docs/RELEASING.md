# Releasing NanoSec

Two layers of version: a **sub-repository version per service** (which the image tag
follows) and a **super-repository version** (which combination of those versions
shipped together). The super-repository version never appears in an image tag — a
one-line fix in one service must not re-tag nine images.

## 1 What is versioned

| Layer | Repository | Version | Changes when |
|---|---|---|---|
| Super-repository | `nanosec` | `v0.x.y` | a submodule pointer or a deployment file moves |
| Image services (9) | `nanoagent`, `nanoadmin`, `nanoartifacts`, `nanoauth`, `nanobus`, `nanogateway`, `nanoportal`, `nanoprovisioner`, `nanoworkspace` | `vX.Y.Z` each | that service alone changes |
| Protocol library | `nanoprotocol` | its own semver (currently `v0.46.0`) | the shared protocol changes; consumed by seven modules, bumped with `scripts/bump-protocol.sh` |

`nanoui` (the Mini Program and its BFF) is **not** in this scheme yet: it has no
image, no compose service and is not a `go.work` module. It may tag itself, but it
is not part of a NanoSec release.

## 2 Images and tags

Images live in **Docker Hub, public, under `kobeyoung81`**
(`docker.io/kobeyoung81/<service>`), so a cluster needs no pull secret.

| Tag | Source | Mutable | Use |
|---|---|---|---|
| `0.1.1` | the service's git tag `v0.1.1` | no | release anchor, rollback target |
| `dev-<short sha>` | every build of the branch head | no | the dev environment, traceability |
| `latest` / `stable` / `0.1` | — | — | **not used** |

The service name, build directory and image name differ in two places and must be
written down once, here:

| compose service | build context | image | version variable |
|---|---|---|---|
| `admin-init`, `nanoadmin` | `./nanoadmin` | `kobeyoung81/nanoadmin` | `NANOADMIN_VERSION` |
| `bus-init`, `nanobus` | `./nanobus` | `kobeyoung81/nanobus` | `NANOBUS_VERSION` |
| `nanoauth` | `./nanoauth` | `kobeyoung81/nanoauth` | `NANOAUTH_VERSION` |
| `nanorunner` | `./nanoprovisioner` | `kobeyoung81/nanoprovisioner` | `NANOPROVISIONER_VERSION` |
| `nanoworkspace` | `./nanoworkspace` | `kobeyoung81/nanoworkspace` | `NANOWORKSPACE_VERSION` |
| `nanogateway` | `./nanogateway` | `kobeyoung81/nanogateway` | `NANOGATEWAY_VERSION` |
| `nanoportal` | `./nanoportal` | `kobeyoung81/nanoportal` | `NANOPORTAL_VERSION` |
| `nanoartifacts` | `./nanoartifacts` | `kobeyoung81/nanoartifacts` | `NANOARTIFACTS_VERSION` |
| `nanosec` | `./nanoagent` | `kobeyoung81/nanoagent` | `NANOAGENT_VERSION` |

The two init containers share their service's image and version variable on
purpose: a released image is what reruns the migrations (see §6).

### 2.1 Base images

The toolchains are not installed by the service builds. Four images are built
once, tagged with their exact contents, and pushed to Docker Hub under
`kobeyoung81`:

| Image | Tag (example) | Built from | Contents |
|---|---|---|---|
| `base-go` | `1.27.4-alpine3.24-r2` | `docker/base/go.Dockerfile` | `golang:1.27.4-alpine3.24` + git, ca-certificates, tzdata; `GOPROXY`/`GOFLAGS`/`CGO_ENABLED` fixed |
| `base-runtime` | `alpine3.24.4-r2` | `docker/base/runtime.Dockerfile` | `alpine:3.24.4` + ca-certificates, tzdata |
| `base-node` | `26.13.1-alpine3.24-r2` | `docker/base/node.Dockerfile` | `node:26.13.1-alpine3.24` + npm registry set globally |
| `nanoagent-runtime` | `24.04-node26.13.1-go1.27.4-r2` | `nanoagent/runtime-base/Dockerfile` | Ubuntu 24.04 tool layer for agent containers: apt packages, nvm/Node, Go, officecli, md2pdf |

The version matrix lives in **`docker/base/versions.env`** (Go, Alpine, Node,
`BASE_REV`). The agent runtime carries its own versions in its Dockerfile
because it is a different kind of image (an application runtime, not a builder).

To bump a toolchain:

1. edit `docker/base/versions.env` (and the agent runtime Dockerfile's ARGs),
2. bump `BASE_REV` — a tag is a promise about the contents, never rebuild one,
3. run `Ops.BaseImages` with `PUSH=true` (or `scripts/base/build-base-images.sh --push`),
4. update the `FROM` lines in the service Dockerfiles to the new tag,
5. `preflight` fails any service that still pulls `golang:*`, `node:*`,
   `alpine:*` or `ubuntu:*` directly.

The images are pushed so a fresh machine does not rebuild them; the CI hits the
local copy first. A tag that already exists is never rebuilt in place.

### 2.2 Layer hygiene and the size baseline

Every install and its cleanup share one `RUN`. `preflight` checks it: an
`apt-get install` without `rm -rf /var/lib/apt/lists` in the same statement, or
an `apk add` without `--no-cache`, fails the release. The rules, in short:

* `apk add --no-cache`; `apt-get install --no-install-recommends`, then
  `apt-get clean` and remove `/var/lib/apt/lists`, `/var/cache/apt/archives`,
  `/usr/share/doc`, `/usr/share/man`, `/usr/share/info` — nothing at runtime
  reads them, and `man` is not installed;
* remove what the installer only needed while installing: `/tmp/*`,
  `$NVM_DIR/.cache`, `$NVM_DIR/.git`, `/root/.npm`,
  `/usr/local/go/{doc,test,api,misc}`;
* multi-stage: compilers, git clones and node_modules stay in the build stage;
* `--mount=type=cache` keeps the Go module cache, the Go build cache and the npm
  cache **outside** the image. They are build machinery, not image content.

Sizes are recorded here after each base image build (`Ops.BaseImages` prints
every layer). The budget is a ceiling, not a target:

| Image | Budget |
|---|---|
| `base-go` | upstream `golang` + ≤ 15 MB |
| `base-runtime` | ≤ 12 MB |
| `base-node` | upstream `node` + ≤ 5 MB |
| `nanoagent-runtime` | no install layer above 450 MB; total ≤ 1.60 GB |
| `nanoagent` (final) | does not grow: ≤ 1.60 GB |

`docker builder prune` keeps cache mounts unless `--all` is passed. Use
`docker builder prune --keep-storage=20GB`; `--all` throws away the build cache
this project depends on and the next build falls back to minutes.

## 3 What the reproducibility gate checks, and why not the image digest

The original proposal compared image digests between a dev build and a rebuild from
the tag, and stopped the promotion when they differed. **That check cannot pass on
this toolchain**, and the measurement below is why.

Method: two contexts extracted from the same `git archive` of one commit, two
`docker build --no-cache` runs each, then compare the image ID and the artifact.

| Observation | Result |
|---|---|
| image ID, same commit, two builds (nanobus) | **different** every time |
| image ID, same directory, two `--no-cache` builds | **different** |
| image ID, trivial `FROM alpine` + `COPY` | identical |
| image ID, trivial `FROM alpine` + `RUN apk add …` | **different** |
| main binary's sha256, two independent builds | **identical** for all five measured services (`nanobus`, `nanoauth`, `nanogateway`, `nanoprovisioner`, `nanoagent`; `nanoagent`'s `md2pdf` and syntax files too) |
| frontend `dist/` manifests, two builds in different directories | **identical**, except `ui/dist/@mf-types.zip` |

Cause: reproducibility breaks in `RUN` layers that write to the filesystem (`apk
add`, `go mod download`): the layer carries file timestamps and packing order, and
this builder (Docker 28.2.2, buildx 0.24.0, BuildKit 0.22) has no
`--rewrite-timestamp`; the exporter option `-o type=docker,rewrite-timestamp=true` is
accepted but does not make the layers match. `COPY`-only layers are already stable.

So the gate compares **what the build produced**, not how the layers were packed:

- **Every service**: sha256 of the main binary inside the image
  (`/usr/local/bin/<svc>`, `/usr/local/bin/nanorunner`, `/app/nanoportal-server`).
  `nanoagent` additionally covers `/usr/local/bin/md2pdf` and the md2pdf syntax
  files, because those come from a pinned clone rather than from the repository.
- **The five services that ship a front end** (`nanoportal`, `nanoartifacts`,
  `nanoworkspace`, `nanoadmin`, `nanoauth`): also a sorted `sha256sum` manifest of
  the built `dist/` tree, **excluding `@mf-types.zip`** — it is a zip the Module
  Federation plugin writes with embedded timestamps, and everything it contains
  (the `.d.ts` files) is already in the manifest.

The image digest is still recorded in `versions.lock` for audit; it never blocks a
release.

## 4 Labels

Every image carries:

```
org.opencontainers.image.title      <service>
org.opencontainers.image.version    <tag, without the v>
org.opencontainers.image.revision   <the service's commit, not the super-repository's>
org.opencontainers.image.created    <SOURCE_DATE_EPOCH: the tagged commit's time>
org.opencontainers.image.source     https://gitee.com/kobeyoung81/<service>
org.opencontainers.image.licenses   <that repository's LICENSE>
```

`created` is derived from the commit, never from the build clock, so two builds of
one tag describe the same moment.

## 5 `versions.lock`

Generated, never hand-written (`scripts/release/render-lock.sh`, P1). JSON because
both Go and `jq` read it without a Jenkins plugin.

```json
{
  "release": "v0.2.0",
  "superproject": { "tag": "v0.2.0" },
  "protocol":     { "version": "0.46.0", "commit": "…" },
  "services": {
    "nanobus": {
      "version": "0.1.1",
      "commit": "…",
      "image": "docker.io/kobeyoung81/nanobus:0.1.1",
      "image_digest": "sha256:…",
      "artifact_digest": "sha256:…"
    }
  }
}
```

`superproject` deliberately carries **no commit**: a file cannot record the hash of
the commit that contains it. The lock is written before the release tag exists (the
tag has to point at the commit that carries the lock), so recording "the commit I was
rendered on" would always name the previous commit, and every check from a tag
checkout would fail. The tag is the anchor; `git rev-parse v0.2.0` recovers the
commit. Locks written before this decision still carry the field; `check-lock.sh`
ignores it.

`check-lock.sh` fails the release when: the checkout is not the release the lock
names (compared by **tag**; `--pre-tag` tolerates an untagged HEAD, which is the
moment between committing the lock and creating the tag), a submodule is not on the
locked commit or differs from the gitlink, a service's `nanoprotocol` requirement
differs from `protocol.version`, or — with `--artifacts` — the image label or the
artifact digest differs from the lock.

## 6 Release flow

1. **Service**: change, test, bump its version, tag, build from the tag, push
   `<version>` **and** `dev-<sha>`.
2. **Protocol** (only when it changed): `scripts/bump-protocol.sh vX.Y.Z`. It must
   update every consumer — seven modules require the protocol, not four.
3. **Super-repository**, on `master` and in this order: move the submodule
   pointers → `render-lock.sh <release>` (it refuses if the release tag already
   exists, or if anything but `versions.lock` is uncommitted) → commit the lock →
   `tag-release.sh super <release>` (it runs `check-lock.sh --pre-tag` first) →
   push **the branch and the tag**. A release whose lock lives only on a tag leaves
   `master` without the history of what shipped.
4. **Deploy**: `compose up -d --no-build`. Because a release tag is never reused,
   the init containers' image reference changes and they run again — **a reused tag
   is a release whose migrations never ran**. Verify both init containers exited 0.
5. **Agent images** are not compose configuration: `runner.agentImage` lives in the
   configuration store. Set it
   (`nanoadmin config set runner agentImage kobeyoung81/nanoagent:<version>`) and note
   in the release record that running agent containers keep their image until they
   are restarted or reprovisioned.
6. **Clean up**: keep the current release, the previous one, and the two most recent
   `dev-<sha>` tags per service. The retention window is the rollback window.

## 7 Branches

`release/0.x` exists in the super-repository and in all eleven submodules, and is
created **when a released minor needs a patch**, at that minor's last tag. It takes
cherry-picked fixes only, never features, and **every fix that lands there must also
land on `master`**, otherwise the next minor silently reverts it. Tags are made on
the release branch; the same fix therefore has two different commits, and the lock
records whichever one the release points at.

Feature branches stay short-lived, as before: `release/*` is the only long-lived
ref besides `master`.

## 8 Rollback

Redeploy with the previous `versions.lock`; only the services whose version differs
are recreated. Migrations must stay compatible with the previous release (N-1): a
rollback that only changes code must not need a schema rollback, so destructive
changes are split into "add" and "remove one release later".

## 9 What is in place, and what is not

In place (2026-11-17):

- `-trimpath` in every Dockerfile, OCI labels on every image, and the version
  stamped into each binary (`main.version`, plus `main.commit`/`main.date` where the
  binary has them).
- `/healthz` reports `{"status":"ok","version":…}` on every service, so a container
  can be asked what it runs without inspecting labels.
- Compose takes `${SERVICE_VERSION}` per image (default `nanosec` for local work) and
  passes `VERSION`/`COMMIT`/`BUILD_DATE` as build args; the k8s and swarm manifests
  carry `${SERVICE_VERSION}` tokens and are rendered from a lock.
- `scripts/release/`: `render-lock.sh`, `check-lock.sh` (`--artifacts`,
  `--pre-tag`), `artifact-digest.sh`, `render-manifests.sh`.
- `scripts/bump-protocol.sh` updates all six consumers of `nanoprotocol` and every
  consumer now requires the same protocol version.

Also in place: `preflight.sh` (clean trees, pushed, submodules at their gitlinks,
git identity present, one protocol version, no floating tags, `-trimpath` and labels
present) and `tag-release.sh` (`services` / `super` / `branch` modes, dry run unless
`--apply`; `super` validates with `check-lock.sh --pre-tag` and pushes the branch as
well as the tag).

First release is done: `v0.1.0` (super-repository and all nine services), images on
Docker Hub, `versions.lock` committed to `master`. Still open: the `release/0.x`
branches (created when a line needs a patch, by `tag-release.sh branch`), and the
Jenkins jobs that drive a release end to end.

## 10 The commands

```sh
# 1. nothing may be dirty, unpushed or off its gitlink
scripts/release/preflight.sh

# 2. tag the services. A service with no commits since its last tag is left on
#    that tag; a changed one needs its version said out loud. Dry run first.
scripts/release/tag-release.sh services v0.1.0 \
  --nanoagent=0.1.0 --nanoadmin=0.1.0 --nanoartifacts=0.1.0 --nanoauth=0.1.0 \
  --nanobus=0.1.0 --nanogateway=0.1.0 --nanoportal=0.1.0 \
  --nanoprovisioner=0.1.0 --nanoworkspace=0.1.0
scripts/release/tag-release.sh services v0.1.0 ... --apply

# 3. build from those tags and push <version> and dev-<sha> to Docker Hub
#    (Jenkins, or by hand), then:

# 4. write the lock, commit it, and only then tag the super-repository. The tag
#    must point at the commit that carries the lock, so these cannot be reordered.
scripts/release/render-lock.sh v0.1.0
git add versions.lock && git commit -m "release: v0.1.0"
scripts/release/check-lock.sh --pre-tag

# 5. tag (it re-runs check-lock --pre-tag) and push the branch and the tag
scripts/release/tag-release.sh super v0.1.0 --apply
scripts/release/render-manifests.sh /tmp/nanosec-manifests

# 6. afterwards, from a tag checkout (this is what Stg.NanoSec runs)
scripts/release/check-lock.sh --artifacts

# a patch release on an existing line
scripts/release/tag-release.sh branch 0.1          # once, when 0.1 needs a patch
```

Local builds keep the `nanosec` tag: `${SERVICE_VERSION:-nanosec}` is the compose
default, so the image tag and the `version` label agree locally without anyone
having to invent a release number.
