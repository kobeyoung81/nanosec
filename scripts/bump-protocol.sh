#!/usr/bin/env bash
# Usage: ./scripts/bump-protocol.sh v0.2.0
# Tags nanoprotocol at HEAD, then updates all consumer go.mod files.
set -e

VERSION=$1
[ -z "$VERSION" ] && echo "Usage: $0 <version>" && exit 1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_MODULES="gitee.com/kobeyoung81/*"
GIT_SSH_REWRITE_PREFIX="ssh://git@gitee.com/"
GIT_HTTPS_PREFIX="https://gitee.com/"

# Force git operations spawned by `go get` / `go mod tidy` to fetch gitee.com
# modules over SSH instead of HTTPS.
GO_GIT_SSH_ENV=(
  "GIT_CONFIG_COUNT=1"
  "GIT_CONFIG_KEY_0=url.${GIT_SSH_REWRITE_PREFIX}.insteadof"
  "GIT_CONFIG_VALUE_0=${GIT_HTTPS_PREFIX}"
)

# Treat the gitee.com/kobeyoung81 modules as private so `go get` skips the
# configured proxy and checksum database for protocol bumps.
GO_PRIVATE_FETCH_ENV=(
  "${GO_GIT_SSH_ENV[@]}"
  "GOWORK=off"
  "GOPRIVATE=${PRIVATE_MODULES}"
  "GONOSUMDB=${PRIVATE_MODULES}"
  "GONOPROXY=${PRIVATE_MODULES}"
)

echo "Tagging nanoprotocol $VERSION..."
# Annotated tag so `git describe` / `git submodule status` resolve it (plain
# describe ignores lightweight tags).
(cd "$REPO_ROOT/nanoprotocol" && git tag -a "$VERSION" -m "$VERSION" && git push origin "$VERSION")

for mod in nanobus nanogateway nanosec nanorunner; do
  echo "Updating $mod..."
  (
    cd "$REPO_ROOT/$mod" &&
      env "${GO_PRIVATE_FETCH_ENV[@]}" go mod edit -dropreplace gitee.com/kobeyoung81/nanoprotocol &&
      env "${GO_PRIVATE_FETCH_ENV[@]}" go get gitee.com/kobeyoung81/nanoprotocol@"$VERSION" &&
      env "${GO_PRIVATE_FETCH_ENV[@]}" go mod tidy &&
      git add go.mod go.sum &&
      git commit -m "chore: bump nanoprotocol to $VERSION" &&
      # Push to the branch explicitly: submodules are often checked out in a
      # detached HEAD state, where a bare `git push` fails.
      git push origin HEAD:master
  )
done

echo "Done. All submodules committed and pushed."
