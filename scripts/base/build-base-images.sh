#!/bin/sh
# Build (and optionally push) the NanoSec base images.
#
# Usage: scripts/base/build-base-images.sh [--only go|runtime|node|agent|all]
#                                          [--push|--no-push] [--dry-run]
#
# Reads docker/base/versions.env, builds in dependency order, prints the size of
# every image and of every layer, and only then (with --push) pushes to Docker
# Hub. Nothing here removes local cache: the cache mounts the service builds use
# are worth more than the disk they take.
#
# The images are immutable: a tag is a promise about the contents. Change a
# version, bump BASE_REV, rebuild, and point the services at the new tag. Never
# rebuild a tag that already exists somewhere else.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

[ -f docker/base/versions.env ] || { echo "missing docker/base/versions.env" >&2; exit 1; }
# shellcheck disable=SC1091
. docker/base/versions.env

BASE_REV=${BASE_REV:-r1}
GO_TAG="${GO_VERSION}-alpine${GO_ALPINE}-${BASE_REV}"
RUNTIME_TAG="alpine${RUNTIME_ALPINE}-${BASE_REV}"
NODE_TAG="${NODE_VERSION}-alpine${NODE_ALPINE}-${BASE_REV}"

only=all
push=false
dry=false
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only=$2; shift 2 ;;
    --push) push=true; shift ;;
    --no-push) push=false; shift ;;
    --dry-run) dry=true; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "build-base-images: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# size_of IMAGE — bytes, or "?" when the image is not there.
size_of() {
  docker image inspect "$1" 2>/dev/null | grep -o '"Size": *[0-9]*' | head -1 | tr -cd '0-9'
}

report() {
  image=$1
  bytes=$(size_of "$image")
  if [ -n "$bytes" ]; then
    echo "    size: $((bytes / 1024 / 1024)) MiB"
    echo "    layers (largest last):"
    docker history --no-trunc --human "$image" | sed -n '2,10p' | sed 's/^/      /'
  fi
}

build() {
  name=$1
  tag=$2
  file=$3
  if [ "$only" != all ] && [ "$only" != "$name" ]; then
    return 0
  fi
  image="kobeyoung81/base-${name}:${tag}"
  echo "==> ${image}"
  if [ "$dry" = true ]; then
    echo "    would run: docker build --platform linux/amd64 -f ${file} -t ${image} docker/base"
    return 0
  fi
  docker build --platform linux/amd64 \
    --build-arg GO_VERSION="$GO_VERSION" \
    --build-arg GO_ALPINE="$GO_ALPINE" \
    --build-arg RUNTIME_ALPINE="$RUNTIME_ALPINE" \
    --build-arg NODE_VERSION="$NODE_VERSION" \
    --build-arg NODE_ALPINE="$NODE_ALPINE" \
    -f "$file" -t "$image" docker/base
  report "$image"
  if [ "$push" = true ]; then
    echo "    pushing"
    docker push "$image"
  fi
}

# base-go first: the agent runtime builds md2pdf with it.
build go        "$GO_TAG"      docker/base/go.Dockerfile
build runtime   "$RUNTIME_TAG" docker/base/runtime.Dockerfile
build node      "$NODE_TAG"    docker/base/node.Dockerfile

# The agent runtime lives in its own repository (nanoagent), because it is an
# application runtime rather than a build toolchain, and its ARGs are bumped
# there. It still builds here so one job owns every base image.
if [ "$only" = all ] || [ "$only" = agent ]; then
  image="kobeyoung81/nanoagent-runtime:${AGENT_RUNTIME_TAG}"
  echo "==> ${image}"
  if [ "$dry" = true ]; then
    echo "    would run: docker build --platform linux/amd64 -f nanoagent/runtime-base/Dockerfile -t ${image} nanoagent/runtime-base"
  else
    docker build --platform linux/amd64 -t "$image" nanoagent/runtime-base
    report "$image"
    if [ "$push" = true ]; then
      echo "    pushing"
      docker push "$image"
    fi
  fi
fi

echo
echo "==> tags"
echo "    base-go:      kobeyoung81/base-go:${GO_TAG}"
echo "    base-runtime: kobeyoung81/base-runtime:${RUNTIME_TAG}"
echo "    base-node:    kobeyoung81/base-node:${NODE_TAG}"
echo "    agent:        kobeyoung81/nanoagent-runtime:${AGENT_RUNTIME_TAG}"
if [ "$push" = false ]; then
  echo "    (not pushed; re-run with --push to publish)"
fi
