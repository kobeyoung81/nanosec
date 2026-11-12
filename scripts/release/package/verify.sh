#!/bin/sh
# Verify a running MyriadMind stack installed from this release.
cd "$(dirname "$0")"
FAIL=0

check() {
  if curl -fsS -m 5 "$1" >/dev/null 2>&1; then echo "OK   $1"; else echo "FAIL $1"; FAIL=1; fi
}

echo "== images"
for i in nanobus nanoauth nanorunner nanogateway nanoportal nanosec; do
  if docker image inspect "kobeyoung81/$i:latest" >/dev/null 2>&1; then echo "OK   image $i"; else echo "FAIL image $i"; FAIL=1; fi
done

echo "== health"
check http://localhost:9000/healthz
check http://localhost:18080/healthz
check http://localhost:28080/

echo "== compose ps"
docker compose -p myriadmind -f compose/docker-compose.yml --env-file compose/.env ps || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "== recent logs (bus-init / nanobus)"
  docker compose -p myriadmind -f compose/docker-compose.yml --env-file compose/.env logs --tail=50 bus-init nanobus || true
  exit 1
fi
echo "ALL OK"
