#!/usr/bin/env bash
# Usage: check-lock.sh [--artifacts]
#
# Validates versions.lock against the checkout. With --artifacts it also
# recomputes every artifact digest from the local images, which is the check a
# promotion runs: the release image must be the build the dev image was.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

want_artifacts=0
[ "${1:-}" = "--artifacts" ] && want_artifacts=1

[ -f versions.lock ] || { echo "check-lock: versions.lock is missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "check-lock: jq is required" >&2; exit 1; }

fail=0
note() { printf '  %-16s %s\n' "$1" "$2"; }
bad() { printf '  FAIL %-13s %s\n' "$1" "$2" >&2; fail=1; }

release=$(jq -r '.release' versions.lock)
echo "release $release"

# 1. the super-repository is what the lock says
commit=$(git rev-parse HEAD)
locked_super=$(jq -r '.superproject.commit' versions.lock)
[ "$commit" = "$locked_super" ] && note super "$commit" || bad super "lock says $locked_super, checkout is $commit"

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
consumers=$(grep -l 'gitee.com/kobeyoung81/nanoprotocol v' */go.mod | cut -d/ -f1 | sort)
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
  done < <(jq -r '.services | keys[]' versions.lock)
fi

if [ "$fail" -ne 0 ]; then
  echo "check-lock: FAILED" >&2
  exit 1
fi
echo "check-lock: ok"
