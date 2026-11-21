#!/usr/bin/env bash
# Usage: preflight.sh
#
# Everything a release assumes, checked before anyone tags anything: clean trees,
# every submodule on its gitlink and on master, one protocol version across the
# consumers, no `latest` left in the manifests, and every Dockerfile still able to
# produce a traceable, reproducible image.
#
# Exit 0 means "a release may start"; anything printed under FAIL is why not.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

SERVICES=(nanoagent nanoadmin nanoartifacts nanoauth nanobus nanogateway nanoportal nanoprovisioner nanoworkspace)
fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=1; }

echo "==> working trees"
if [ -z "$(git status --porcelain)" ]; then ok "super-repository clean"; else bad "super-repository has uncommitted changes"; fi
for svc in "${SERVICES[@]}" nanoprotocol nanoui; do
  [ -d "$svc" ] || continue
  if [ -z "$(git -C "$svc" status --porcelain)" ]; then ok "$svc clean"; else bad "$svc has uncommitted changes"; fi
done

echo "==> the checkout matches what was pushed"
git fetch -q origin || bad "git fetch failed"
if [ -z "$(git rev-list origin/master..HEAD)" ]; then ok "super-repository has nothing unpushed"; else bad "super-repository is ahead of origin/master"; fi
for svc in "${SERVICES[@]}" nanoprotocol; do
  [ -d "$svc" ] || continue
  git -C "$svc" fetch -q origin 2>/dev/null || true
  if [ "$(git -C "$svc" rev-parse --abbrev-ref HEAD)" != "HEAD" ] &&
     [ "$(git -C "$svc" rev-parse --abbrev-ref HEAD)" != "master" ]; then
    bad "$svc is on $(git -C "$svc" rev-parse --abbrev-ref HEAD), not master"
    continue
  fi
  if [ -n "$(git -C "$svc" rev-list origin/master..HEAD 2>/dev/null)" ]; then
    bad "$svc is ahead of origin/master"
  else
    ok "$svc pushed"
  fi
done

echo "==> git identity (tagging needs one)"
if git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then ok "super-repository has an identity"; else bad "super-repository has no git identity: set GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL or git config --global user.name/user.email"; fi
for svc in "${SERVICES[@]}"; do
  [ -d "$svc" ] || continue
  if git -C "$svc" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    ok "$svc has an identity"
  else
    bad "$svc has no git identity (a submodule does not inherit the super-repository's local config)"
  fi
done

echo "==> submodules pinned to what is checked out"
# `git submodule status` prints " <sha> <path> (<ref>)", with a leading +, - or U
# when the checkout is not at the gitlink; read the sha first and strip the mark.
while read -r sha path rest; do
  case "$sha" in
    +*|-*|U*) bad "$path is not at its gitlink (${sha:0:1})"; continue ;;
  esac
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null || echo missing)
  if [ "$head" = "$sha" ]; then ok "$path at ${sha:0:12}"; else bad "$path at $head, gitlink says $sha"; fi
done < <(git submodule status)

echo "==> one protocol version"
proto=$(git -C nanoprotocol describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$proto" ]; then
  bad "nanoprotocol has no tag"
else
  ok "nanoprotocol $proto"
  for mod in $(grep -l 'gitee.com/kobeyoung81/nanoprotocol v' */go.mod | cut -d/ -f1 | sort); do
    required=$(sed -n 's/.*gitee.com\/kobeyoung81\/nanoprotocol \(v[0-9][0-9A-Za-z.+-]*\).*/\1/p' "$mod/go.mod" | head -1)
    if [ "$required" = "$proto" ]; then ok "$mod requires $proto"; else bad "$mod requires ${required:-none}, want $proto"; fi
  done
fi

echo "==> no floating image tags"
if hits=$(grep -rn ':latest' docker-compose.yml deploy/ 2>/dev/null); then
  bad "floating tags remain:"; printf '%s\n' "$hits" >&2
else
  ok "no :latest in compose or deploy"
fi

echo "==> only our base images"
# Why: the toolchain is pinned in one place (docker/base/versions.env and the
# agent runtime) and rebuilt by Ops.BaseImages. A service that pulls golang:*,
# node:* or alpine:* directly re-introduces the drift and the slow installs this
# setup exists to remove.
base_ok=1
for svc in "${SERVICES[@]}"; do
  df="$svc/Dockerfile"
  [ -f "$df" ] || continue
  while read -r _ ref _rest; do
    case "$ref" in
      "" | AS | as) continue ;;
      kobeyoung81/base-* | kobeyoung81/nanoagent-runtime:* | scratch) ;;
      *) bad "$df: FROM $ref is not a NanoSec base image"; base_ok=0 ;;
    esac
  done < <(grep -E '^[[:space:]]*FROM ' "$df")
done
if grep -rn ':latest' docker/base/*.Dockerfile >/dev/null 2>&1; then
  bad "docker/base/Dockerfile pins :latest"; base_ok=0
fi
[ "$base_ok" -eq 1 ] && ok "every FROM is a NanoSec base image, none floats"

echo "==> installs clean up after themselves"
# Why: an install and its cleanup must live in the same RUN, or the package
# cache, man pages and docs become permanent layers (hundreds of MB in the agent
# runtime). This walks each RUN statement (backslash continuations joined) and
# requires the matching cleanup in that same statement.
hygiene_ok=1
check_hygiene() {
  awk '
    s != "" { s = s " " $0; if ($0 !~ /\\[[:space:]]*$/) { print s; s = "" }; next }
    /^[[:space:]]*RUN / { s = $0; if ($0 !~ /\\[[:space:]]*$/) { print s; s = "" } }
  ' "$1" | while IFS= read -r stmt; do
    case "$stmt" in
      *"apt-get install"*)
        case "$stmt" in
          *"rm -rf /var/lib/apt/lists"*) ;;
          *) echo "    apt-get install without removing /var/lib/apt/lists in the same RUN"; exit 1 ;;
        esac ;;
    esac
    case "$stmt" in
      *"apk add"*)
        case "$stmt" in
          *"--no-cache"*) ;;
          *) echo "    apk add without --no-cache"; exit 1 ;;
        esac ;;
    esac
  done
}
for svc in "${SERVICES[@]}"; do
  df="$svc/Dockerfile"
  [ -f "$df" ] || continue
  if ! out=$(check_hygiene "$df"); then
    bad "$df:${out#*$'\n'}"; hygiene_ok=0
  fi
done
if [ -f nanoagent/runtime-base/Dockerfile ]; then
  if ! out=$(check_hygiene nanoagent/runtime-base/Dockerfile); then
    bad "nanoagent/runtime-base/Dockerfile:${out#*$'\n'}"; hygiene_ok=0
  fi
fi
[ "$hygiene_ok" -eq 1 ] && ok "every install is cleaned up in its own RUN"

echo "==> every image stays traceable and reproducible"
dockerfiles_ok=1
for svc in "${SERVICES[@]}"; do
  df="$svc/Dockerfile"
  [ -f "$df" ] || { bad "$df is missing"; dockerfiles_ok=0; continue; }
  grep -q -- '-trimpath' "$df" || { bad "$df does not build with -trimpath"; dockerfiles_ok=0; }
  grep -q 'org.opencontainers.image.version' "$df" || { bad "$df has no version label"; dockerfiles_ok=0; }
  grep -q 'org.opencontainers.image.revision' "$df" || { bad "$df has no revision label"; dockerfiles_ok=0; }
done
[ "$dockerfiles_ok" -eq 1 ] && ok "all nine Dockerfiles carry -trimpath and OCI labels"

echo
if [ "$fail" -ne 0 ]; then
  echo "preflight: FAILED" >&2
  exit 1
fi
echo "preflight: ok"
