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
  "superproject": { "tag": "v0.2.0", "commit": "…" },
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

`check-lock.sh` (P1) fails the release when: a submodule is not exactly on a tag,
`lock.commit` differs from the gitlink, a service's `nanoprotocol` requirement
differs from `protocol.version`, or an `artifact_digest` differs between the dev
build and the rebuild from the tag.

## 6 Release flow

1. **Service**: change, test, bump its version, tag, build from the tag, push
   `<version>` **and** `dev-<sha>`.
2. **Protocol** (only when it changed): `scripts/bump-protocol.sh vX.Y.Z`. It must
   update every consumer — seven modules require the protocol, not four.
3. **Super-repository**: move the submodule pointers, `render-lock.sh`,
   `check-lock.sh`, commit, tag.
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

## 9 Not done yet (P1/P2)

The gate is described here and the builds satisfy it; the automation is not written
yet: `render-lock.sh`, `check-lock.sh`, `tag-release.sh`, the compose version
variables, the k8s/swarm tag variables, `version` on `/healthz`, and rewriting
`scripts/release/build-release.sh` (still the pre-P1 offline packager: `:latest`,
six images, database `nanobus`, ports 18080/28080).
