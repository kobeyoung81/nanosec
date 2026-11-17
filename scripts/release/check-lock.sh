#!/usr/bin/env bash
# Usage: check-lock.sh [--artifacts]
#
# Validates versions.lock against the checkout. With --artifacts it also
# recomputes every artifact digest from the local images and checks their OCI
# labels, which is the check a promotion runs: the image behind a tag must be the
# build the lock describes.
#
# With --pre-tag it tolerates an untagged HEAD: that is the moment between
# committing the lock and creating the release tag, and `tag-release.sh super`
# validates there. If HEAD already carries a tag, it is still compared.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

want_artifacts=0
pre_tag=0
for arg in "$@"; do
  case "$arg" in
    --artifacts) want_artifacts=1 ;;
    --pre-tag)   pre_tag=1 ;;
    *) echo "check-lock: unknown argument $arg" >&2; exit 2 ;;
  esac
done

[ -f versions.lock ] || { echo "check-lock: versions.lock is missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "check-lock: jq is required" >&2; exit 1; }

fail=0
note() { printf '  %-16s %s\n' "$1" "$2"; }
bad() { printf '  FAIL %-13s %s\n' "$1" "$2" >&2; fail=1; }

release=$(jq -r '.release' versions.lock)
echo "release $release"

# 1. the super-repository is the release the lock names.
#
# The lock deliberately records no commit: a file cannot contain the hash of the
# commit that contains it, so comparing hashes could never pass from a tag
# checkout. The tag is the anchor; `git rev-parse <tag>` recovers the commit.
locked_tag=$(jq -r '.superproject.tag // .release' versions.lock)
head_tag=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
if [ "$head_tag" = "$locked_tag" ]; then
  note super "$locked_tag"
elif [ "$pre_tag" -eq 1 ] && [ -z "$head_tag" ]; then
  note super "pre-tag (HEAD untagged)"
else
  bad super "lock says $locked_tag, checkout is ${head_tag:-untagged}"
fi

# 2. every service is the locked commit, and that commit is the gitlink
while read -r svc; do
  locked=$(jq -r --arg s "$svc" '.services[$s].commit' versions.lock)
  gitlink=$(git ls-tree HEAD "$svc" | awk '{print $3}')
  head=$(git -C "$svc" rev-parse HEAD 2>/dev/null || echo missing)
  if [ "$locked" = "$gitlink" ] && [ "$locked" = "$head" ]; then
    note "$svc" "${locked:0:12}"
  else
    bad "$svc" "lock $locked / gitlink $gitlink / checkout $head"
  fi
done < <(jq -r '.services | keys[]' versions.lock)

# 3. the protocol version the lock names is the one every consumer requires
proto=$(jq -r '.protocol.version' versions.lock)
# The protocol module itself matches the name; only its consumers require it.
# A tree without go.mod files (a scratch checkout, an offline bundle) has no
# consumers to compare; that is not a failure. grep exits nonzero either way, so
# the pipeline must not take the script down with it.
consumers=$(grep -l 'gitee.com/kobeyoung81/nanoprotocol v' */go.mod 2>/dev/null | cut -d/ -f1 | sort || true)
[ -n "$consumers" ] || note protocol "no consumers in this tree"
for mod in $consumers; do
  required=$(sed -n 's/.*gitee.com\/kobeyoung81\/nanoprotocol \(v[0-9][0-9A-Za-z.+-]*\).*/\1/p' "$mod/go.mod" | head -1)
  if [ "$required" = "v$proto" ]; then
    note "$mod" "protocol v$proto"
  else
    bad "$mod" "requires ${required:-none}, lock says v$proto"
  fi
done

# 4. the images behind those tags still hash to the recorded artifact
if [ "$want_artifacts" -eq 1 ]; then
  while read -r svc; do
    image=$(jq -r --arg s "$svc" '.services[$s].image' versions.lock)
    locked=$(jq -r --arg s "$svc" '.services[$s].artifact_digest' versions.lock)
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      bad "$svc" "image $image is not present locally"
      continue
    fi
    actual=$("$root/scripts/release/artifact-digest.sh" "$svc" "$image")
    if [ "$actual" = "$locked" ]; then
      note "$svc" "artifact ${actual:0:19}…"
    else
      bad "$svc" "artifact $actual, lock says $locked"
    fi

    # The tag is only trustworthy when the image says the same thing: a push that
    # overwrote a tag with a different build would otherwise pass on the digest.
    want_version=$(jq -r --arg s "$svc" '.services[$s].version' versions.lock)
    want_commit=$(jq -r --arg s "$svc" '.services[$s].commit' versions.lock)
    label_version=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
    label_revision=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)
    if [ "$label_version" = "$want_version" ] && [ "$label_revision" = "$want_commit" ]; then
      note "$svc" "labels $label_version/$label_revision"
    else
      bad "$svc" "labels ${label_version:-none}/${label_revision:-none}, lock says $want_version/$want_commit"
    fi
  done < <(jq -r '.services | keys[]' versions.lock)
fi

if [ "$fail" -ne 0 ]; then
  echo "check-lock: FAILED" >&2
  exit 1
fi
echo "check-lock: ok"
