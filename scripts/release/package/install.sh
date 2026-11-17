#!/bin/sh
# NanoSec offline installer.
#
# Loads the images this release carries and starts the stack from the rendered
# compose file. The versions are already baked into the compose file, so this
# script never chooses one.
#
# Requirements: Docker 20.10+ with Compose v2, and a reachable MongoDB.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

command -v docker >/dev/null 2>&1 || { echo "requires Docker 20.10+"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "requires Docker Compose v2"; exit 1; }

if [ ! -f .env ]; then
  cp .env.example .env
  cat <<'EOF'
==> wrote .env; fill it in and run ./install.sh again:
    1) NANOSEC_BUS_INTERNAL_TOKEN = `openssl rand -hex 24`
    2) NANOSEC_BUS_DATABASE_URI   = the shared database, database name `nanosec`.
       Use the host's LAN IP, not a *.home name: Docker's embedded DNS resolves
       those to 127.0.0.1 inside a container.
EOF
  exit 0
fi

grep -Eq '^NANOSEC_BUS_INTERNAL_TOKEN=.+' .env || { echo "NANOSEC_BUS_INTERNAL_TOKEN is not set in .env"; exit 1; }
grep -Eq '^NANOSEC_BUS_DATABASE_URI=.+' .env || { echo "NANOSEC_BUS_DATABASE_URI is not set in .env"; exit 1; }
if grep -Eq '^NANOSEC_BUS_DATABASE_URI=.*\.home' .env; then
  echo "error: NANOSEC_BUS_DATABASE_URI contains *.home — inside a container that resolves to 127.0.0.1; use the LAN IP"; exit 1
fi

project="${ENV_PREFIX:-}nanosec"

echo "==> loading images"
for f in images/*.tar; do
  echo "    docker load -i $(basename "$f")"
  docker load -i "$f"
done

# down before up: the init containers are `restart: "no"` and the services wait on
# them, so an already-exited init container is not re-run by a plain `up -d`.
# Derived volumes (agent data) are kept — never pass -v.
# No --remove-orphans: it removes any container the project does not name, which
# once took out a service that had been started by hand.
echo "==> stopping the previous stack (volumes kept)"
docker compose -p "$project" -f docker-compose.yml --env-file .env down || true

echo "==> starting"
docker compose -p "$project" -f docker-compose.yml --env-file .env up -d --no-build

echo "==> done; run ./verify.sh next"
