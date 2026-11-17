#!/usr/bin/env bash
# Usage: render-lock.sh <release-tag>   (for example: v0.2.0)
#
# Writes versions.lock from what is actually checked out: each service must be
# exactly on a version tag, and that tag's commit must be the commit the
# super-repository pins in its gitlink. Reads images that are present locally
# and records their digests; a missing image is an error — the lock describes a
# release, not an intention.
set -euo pipefail

release=${1:?usage: render-lock.sh <release-tag>}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

SERVICES=(nanoagent nanoadmin nanoartifacts nanoauth nanobus nanogateway nanoportal nanoprovisioner nanoworkspace)
REGISTRY=${REGISTRY:-docker.io/kobeyoung81}

err() { echo "render-lock: $*" >&2; exit 1; }

# Semantic version only: a lock entry that names `main` or a sha is not a release.
semver_of() {
  local tag
  tag=$(git -C "$1" describe --tags --exact-match HEAD 2>/dev/null) ||
    err "$1 is not exactly on a tag (describe --exact-match failed)"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    err "$1 tag $tag is not a semantic version"
  printf '%s' "${tag#v}"
}

super_tag=$(git describe --tags --exact-match HEAD 2>/dev/null) ||
  err "the super-repository is not exactly on a tag; tag it before rendering the lock"
[ "$super_tag" = "$release" ] || err "HEAD is $super_tag, not $release"

protocol_version=$(semver_of nanoprotocol)
protocol_commit=$(git -C nanoprotocol rev-parse HEAD)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  printf '{\n'
  printf '  "release": "%s",\n' "$release"
  printf '  "superproject": { "tag": "%s", "commit": "%s" },\n' "$release" "$(git rev-parse HEAD)"
  printf '  "protocol": { "version": "%s", "commit": "%s" },\n' "$protocol_version" "$protocol_commit"
  printf '  "services": {\n'
} > "$tmp"

first=1
for svc in "${SERVICES[@]}"; do
  version=$(semver_of "$svc")
  commit=$(git -C "$svc" rev-parse HEAD)
  gitlink=$(git ls-tree HEAD "$svc" | awk '{print $3}')
  [ "$commit" = "$gitlink" ] || err "$svc: HEAD $commit is not the gitlink $gitlink"
  # The tag must actually be on that commit (describe already says so, but a
  # stale local tag would make the two disagree).
  [ "$(git -C "$svc" rev-list -n1 "$(git -C "$svc" describe --tags --exact-match HEAD)")" = "$commit" ] ||
    err "$svc: tag does not point at HEAD"

  image="$REGISTRY/$svc:$version"
  docker image inspect "$image" >/dev/null 2>&1 || err "image $image is not present locally; build and push it first"

  image_digest=$(docker image inspect "$image" --format '{{range .RepoDigests}}{{println .}}{{end}}' |
    sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p' | head -1)
  artifact=$("$root/scripts/release/artifact-digest.sh" "$svc" "$image")

  [ $first -eq 1 ] || printf ',\n' >> "$tmp"
  first=0
  printf '    "%s": { "version": "%s", "commit": "%s", "image": "%s", "image_digest": "%s", "artifact_digest": "%s" }' \
    "$svc" "$version" "$commit" "$image" "${image_digest:-}" "$artifact" >> "$tmp"
done

{
  printf '\n  }\n'
  printf '}\n'
} >> "$tmp"

mv "$tmp" versions.lock
trap - EXIT
echo "wrote versions.lock for $release"
echo "  protocol $protocol_version ($protocol_commit)"
for svc in "${SERVICES[@]}"; do
  printf '  %-16s %s\n' "$svc" "$(git -C "$svc" describe --tags --exact-match HEAD)"
done
