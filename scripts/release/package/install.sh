#!/bin/sh
# MyriadMind offline installer.
# Loads the bundled images and (re)starts the stack using the preloaded images.
# Requirements: Docker 20.10+ with Compose v2, and a reachable MongoDB
# (database "nanobus") configured in compose/.env.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

command -v docker >/dev/null 2>&1 || { echo "requires Docker 20.10+"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "requires Docker Compose v2"; exit 1; }

if [ ! -f compose/.env ]; then
  cp compose/.env.example compose/.env
  cat <<'EOF'
==> 已生成 compose/.env，请编辑后重新运行 ./install.sh：
    1) NANOSEC_BUS_INTERNAL_TOKEN = $(openssl rand -hex 24) 生成的随机串
    2) NANOSEC_BUS_DATABASE_URI   = 外置 MongoDB，库名必须是 nanobus；
       用宿主 LAN IP（如 <host-lan-ip>），不要用 *.home 主机名
EOF
  exit 0
fi

grep -Eq '^NANOSEC_BUS_INTERNAL_TOKEN=.+' compose/.env || { echo "NANOSEC_BUS_INTERNAL_TOKEN 未设置（compose/.env）"; exit 1; }
grep -Eq '^NANOSEC_BUS_DATABASE_URI=.+'   compose/.env || { echo "NANOSEC_BUS_DATABASE_URI 未设置（compose/.env）"; exit 1; }
if grep -Eq '^NANOSEC_BUS_DATABASE_URI=.*\.home' compose/.env; then
  echo "错误：NANOSEC_BUS_DATABASE_URI 含 *.home —— 容器内会解析到 127.0.0.1，请改用宿主 LAN IP"; exit 1
fi

echo "==> loading images"
for f in images/*.tar; do
  echo "    docker load -i $(basename "$f")"
  docker load -i "$f"
done

echo "==> stopping previous stack (volumes kept; never pass -v)"
docker compose -p myriadmind -f compose/docker-compose.yml --env-file compose/.env down --remove-orphans || true

echo "==> starting"
docker compose -p myriadmind -f compose/docker-compose.yml --env-file compose/.env up -d --no-build

echo "==> waiting for nanobus"
for i in $(seq 1 60); do
  if curl -fsS http://localhost:9000/healthz >/dev/null 2>&1; then echo "    nanobus ready"; break; fi
  sleep 2
done
docker compose -p myriadmind -f compose/docker-compose.yml ps
echo
echo "portal : http://<host>:28080"
echo "gateway: http://<host>:18080"
echo "接着可运行 ./verify.sh 做一次健康检查。"
