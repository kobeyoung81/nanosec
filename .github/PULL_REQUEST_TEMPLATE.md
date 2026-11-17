## What this changes

<!-- One paragraph. Say why, not only what. -->

## How it was verified

<!-- Commands you ran and what they printed. A test that never fails proves nothing. -->

- [ ] touched modules build: `cd <module> && go build ./... && go vet ./...`
- [ ] tests pass in every module I changed
- [ ] added or updated a test that fails without this change (behaviour changes only)
- [ ] ran `./scripts/install-hooks.sh` so the pre-commit build check is in place

## Does it touch a contract or a collection?

- [ ] `nanoprotocol` changed — `./scripts/bump-protocol.sh vX.Y.Z` was run and every
      consumer's `go.mod`/`go.sum` is committed in this PR
- [ ] a collection's shape, name or index changed — the owning service declares the
      index in its own manifest, and `docs/ARCHITECTURE.md` §1.4 is updated
- [ ] neither

## Checklist

- [ ] branch is `feat/xxx` or `fix/xxx`, rebased on `master`
- [ ] no secrets, tokens or customer data in the diff
- [ ] documentation updated where behaviour changed (README, `docs/`, or the
      submodule's own README)
