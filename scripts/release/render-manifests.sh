#!/usr/bin/env bash
# Usage: render-manifests.sh <output-dir> [versions.lock]
#
# The k8s and swarm manifests carry ${SERVICE_VERSION} tokens instead of image
# tags, so "what is deployed" can only come from a lock. This substitutes the
# tokens and writes ready-to-apply files; it refuses to render when a token has
# no value, which is the failure that would otherwise reach the cluster as
# `ImagePullBackOff` on a literal `${...}` tag.
set -euo pipefail

out=${1:?usage: render-manifests.sh <output-dir> [versions.lock]}
lock=${2:-versions.lock}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

[ -f "$lock" ] || { echo "render-manifests: $lock is missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "render-manifests: jq is required" >&2; exit 1; }
mkdir -p "$out/k8s" "$out/swarm"

# service -> version, from the lock
declare -A version
while read -r svc; do
  version[$svc]=$(jq -r --arg s "$svc" '.services[$s].version' "$lock")
done < <(jq -r '.services | keys[]' "$lock")

render() {
  local src=$1 dst=$2 line tok svc
  : > "$dst"
  while IFS= read -r line; do
    for tok in $(printf '%s' "$line" | grep -o '\${[A-Z_]*_VERSION}' || true); do
      svc=$(printf '%s' "$tok" | sed 's/\${\([A-Z_]*\)_VERSION}/\1/' | tr 'A-Z' 'a-z')
      [ -n "${version[$svc]:-}" ] || {
        echo "render-manifests: $src names $tok but the lock has no version for $svc" >&2
        exit 1
      }
      line=${line//$tok/${version[$svc]}}
    done
    printf '%s\n' "$line" >> "$dst"
  done < "$src"
}

for src in deploy/k8s/*.yaml; do
  render "$src" "$out/k8s/$(basename "$src")"
done
render deploy/swarm/docker-stack.yml "$out/swarm/docker-stack.yml"

if grep -rn '\${[A-Z_]*_VERSION}' "$out" >/dev/null; then
  echo "render-manifests: a token survived rendering" >&2
  exit 1
fi
echo "rendered $(ls "$out"/k8s/*.yaml | wc -l) k8s manifests and the swarm stack into $out"
