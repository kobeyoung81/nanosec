# Contributing to NanoSec

Thanks for wanting to help. This document covers the setup that actually works
for this repository, the conventions the code follows, and what a pull request has
to contain.

## Setup

Prerequisites: Go 1.26 (the workspace declares 1.26.2), Git with SSH access to
Gitee, and optionally Docker with Compose v2 for the containerized stack.

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/nanosec.git
cd nanosec
./scripts/install-hooks.sh
```

The hook verifies that every submodule still builds **standalone** with
`GOWORK=off` — the pre-commit check exists because a change can pass in the
workspace and fail in the image build, which does not use `go.work`.

If you cloned without submodules:

```bash
git submodule update --init --recursive
```

## Building and testing

The super-repo has **no `go.mod`** — it only has `go.work`. Run the commands inside
the module you changed:

```bash
cd nanoauth
go build ./...
go vet ./...
go test ./...
```

Tests that need a live MongoDB skip themselves unless `NANOSEC_BUS_DATABASE_URI`
(or the module's own `*_MONGO_URI`) points at one. Running them against a real
database is strongly recommended before a pull request that touches a store.

Format with `gofmt -l .` (the answer should be no files) — the CI does not enforce
formatting, the pre-commit hook does.

## Branches and commits

- Branch from `master`: `feat/xxx`, `fix/xxx`, `docs/xxx`, `chore/xxx`.
- Commits follow Conventional Commits with a scope that is the module or area:
  `feat(workspace): own the git panel`, `fix(nanobus): clamp the SSE resume point`,
  `docs: describe the account page`.
- Keep the subject line under 72 characters; put the reasoning in the body.
- One concern per commit. A protocol bump is its own commit.

## The rules the code is built on

1. **One collection, one writer.** A collection belongs to exactly one service;
   every other service reads it over that service's HTTP API. Do not open a second
   connection into somebody else's prefix.
2. **The bus carries messages.** Queues, the event stream, tunnel forwarding. New
   features do not add state to the bus process.
3. **Configuration lives in the admin module**, not in environment variables.
   Environment variables are connection-level only (URIs, the shared token,
   listen addresses).
4. **Never compare marshalled documents byte-for-byte** in a test. Go map order is
   not stable across encodes; compare field by field.

## Changing the protocol

`nanoprotocol` is a Go module with its own tags. The order is fixed:

1. Commit the change in `nanoprotocol`.
2. Run `./scripts/bump-protocol.sh vX.Y.Z` — it tags the protocol and updates every
   consumer's `go.mod`.
3. Commit the `go.mod`/`go.sum` changes in each consumer submodule.
4. Push the submodules **before** the super-repo, so a super-repo checkout never
   points at a tag that is not on the remote yet.

## Pull requests

A pull request should say:

- what changed and why;
- how you verified it — commands and their output, not "tested locally";
- whether it touches `nanoprotocol` or a collection's shape or index.

The template in `.github/PULL_REQUEST_TEMPLATE.md` asks for exactly that. Behaviour
changes need a test that fails without the change; a test that never fails proves
nothing.

## Documentation

- Behaviour change → update the README of the module you touched.
- Shape change (a collection, a prefix, a port) → update `docs/ARCHITECTURE.md` §1.4
  and the owning service's manifest.
- A new design worth discussing → add it under `docs/` and link it from
  `docs/README.md`.

## Security

Do not open a public issue for a vulnerability. See [`SECURITY.md`](./SECURITY.md).
