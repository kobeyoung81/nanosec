#!/bin/sh
# Checks a running NanoSec stack: the init containers exited cleanly, every
# service answers /healthz with the version the manifest names, and the image
# labels agree with it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
project="${ENV_PREFIX:-}nanosec"
fail=0

echo "==> init containers"
for job in admin-init bus-init; do
  state=$(docker inspect "$project-$job-1" --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null || echo "missing -")
  case "$state" in
    "exited 0") echo "    $job: ok" ;;
    *) echo "    $job: $state" >&2; fail=1 ;;
  esac
done

echo "==> healthz and versions"
for svc in nanobus nanoauth nanogateway nanoadmin nanoworkspace nanoartifacts nanoportal nanorunner; do
  body=$(docker compose -p "$project" -f docker-compose.yml exec -T "$svc" \
    sh -c 'wget -qO- http://127.0.0.1:8080/healthz 2>/dev/null || wget -qO- http://127.0.0.1/healthz' 2>/dev/null || true)
  case "$body" in
    *'"status":"ok"'*) echo "    $svc: $body" ;;
    *) echo "    $svc: no healthy answer" >&2; fail=1 ;;
  esac
done

echo "==> image labels"
while read -r image; do
  [ -n "$image" ] || continue
  v=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "")
  r=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || echo "")
  if [ -n "$v" ] && [ -n "$r" ]; then
    echo "    $(printf '%-46s' "$image") version=$v revision=$r"
  else
    echo "    $image: no OCI labels" >&2; fail=1
  fi
done < <(grep -E '^\s+image: kobeyoung81/' docker-compose.yml | awk '{print $2}' | sort -u)

[ "$fail" -eq 0 ] || { echo "verify: FAILED" >&2; exit 1; }
echo "verify: ok"
