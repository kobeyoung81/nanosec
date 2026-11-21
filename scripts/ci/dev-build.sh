#!/bin/sh
# The Dev.NanoSec build, kept in the repository instead of only in the job.
# The job runs: sh scripts/ci/dev-build.sh with $WORKSPACE and $BUILD_NUMBER set.
set -eu
cd "$WORKSPACE"

export GIT_AUTHOR_NAME=kobeyoung81  GIT_AUTHOR_EMAIL=kobeyoung81@sina.com
export GIT_COMMITTER_NAME=kobeyoung81 GIT_COMMITTER_EMAIL=kobeyoung81@sina.com

DS=/var/jenkins_home/dev-secrets
mkdir -p "$DS"

# The L1 step runs in the same toolchain the images are built with. Read the tag
# from the version matrix rather than repeating it: a bump there must not leave a
# second copy behind.
# shellcheck disable=SC1091
. docker/base/versions.env
L1_IMAGE="kobeyoung81/base-go:${GO_VERSION}-alpine${GO_ALPINE}-${BASE_REV}"
echo "L1 image: $L1_IMAGE"

echo "=== preflight ==="
./scripts/release/preflight.sh

SHORT=$(git rev-parse --short HEAD)
SHA=$(git rev-parse HEAD)
TAG="dev-$SHORT"
echo "super HEAD: $SHORT  →  image tag: $TAG"

# Only the modules whose gitlink moved need their tests re-run. A change to
# nanoprotocol or docker/base makes scripts/ci/changed-modules.sh return all of
# them, because both are inputs to every build.
PREV=""
if [ -f "$DS/last-tree.txt" ]; then PREV=$(head -1 "$DS/last-tree.txt"); fi
CHANGED=$(./scripts/ci/changed-modules.sh "$PREV" "$SHA")
echo "changed modules: ${CHANGED:-none}"

echo "=== L1: build / vet / test（变更模块 + nanoprotocol，在 base-go 里跑）==="
# Jenkins 容器没有 Go；base-go 是服务镜像构建用的同一套工具链与同一版本，
# 所以 L1 通过就意味着镜像编得过。两个缓存卷让第二次起不再从零编译。
# -p 1：包的测试串行跑。nanoagent 的 hypervisor 流式测试在 4 vCPU 上并行跑包时
# 会踩 5s 读超时（已在 base-go 里复现，包单独跑 0.7s、并行跑整模块必挂）；
# 串行后稳定 1.5s。模块之间本来就是串行的，代价很小。
# 工作区路径要换成宿主路径（容器内 /var/jenkins_home → 宿主 docker_mounts/jenkins_home）。
HOSTWS=$(echo "$WORKSPACE" | sed 's|^/var/jenkins_home|/home/kobeyoung81/docker_mounts/jenkins_home|')
FLAKY=$DS/flaky.log
L1_START=$(date +%s)
run_l1() {
  docker run --rm --entrypoint sh \
    -v "$HOSTWS":/src \
    -v nanosec-gomod:/root/go/pkg/mod \
    -v nanosec-gocache:/root/.cache/go-build \
    -w "/src/$1" \
    "$L1_IMAGE" \
    -c 'go build ./... && go vet ./... && go test -count=1 -p 1 ./...'
}
if [ -n "$CHANGED" ]; then
  for m in nanoprotocol $CHANGED; do
    echo "--- L1 $m ---"
    if ! run_l1 "$m"; then
      echo "  ! $m 首次失败，重试一次（判断是否 flaky）"
      if run_l1 "$m"; then
        echo "  WARN $m: 首次失败、重试通过（flaky） $(date -Is)" | tee -a "$FLAKY"
      else
        echo "  L1 失败: $m"; exit 1
      fi
    fi
  done
  echo "L1: ok"
else
  echo "L1: skipped（没有模块变更）"
fi
L1_SECONDS=$(( $(date +%s) - L1_START ))
echo "l1: ${L1_SECONDS}s"

# 版本三件套：镜像 tag 与镜像内 version 都用 dev-<sha>，staging 部署后 /healthz 能直接看出是哪个 commit
svc_vars() {
  n=$1; d=$2
  sha=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo none)
  bd=$(git -C "$d" log -1 --format=%cI 2>/dev/null || echo unknown)
  export "${n}_VERSION=$TAG"
  export "${n}_COMMIT=$sha"
  export "${n}_BUILD_DATE=$bd"
  printf '  %-16s %s commit=%.10s\n' "$n" "$TAG" "$sha"
}
svc_vars NANOADMIN nanoadmin
svc_vars NANOBUS nanobus
svc_vars NANOAUTH nanoauth
svc_vars NANOPROVISIONER nanoprovisioner
svc_vars NANOWORKSPACE nanoworkspace
svc_vars NANOGATEWAY nanogateway
svc_vars NANOPORTAL nanoportal
svc_vars NANOARTIFACTS nanoartifacts
svc_vars NANOAGENT nanoagent

# dev 端口与 staging(1440x) 隔离
sed -i 's|127.0.0.1:14400:9000|127.0.0.1:${NANOBUS_PORT:-14400}:9000|' docker-compose.yml
sed -i 's|127.0.0.1:14402:8080|127.0.0.1:${NANOGATEWAY_PORT:-14402}:8080|' docker-compose.yml
sed -i 's|"14403:80"|"${NANOPORTAL_PORT:-14403}:80"|' docker-compose.yml

echo "=== build（本地，不推 Docker Hub）==="
# 4 vCPU / 16 GB，宿主上还跑着几十个容器：两个并发足够，再多只会互相抢缓存。
export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-2}"
export BUILDKIT_PROGRESS=plain
BUILD_START=$(date +%s)
docker compose --profile agent build
BUILD_SECONDS=$(( $(date +%s) - BUILD_START ))
echo "build: ${BUILD_SECONDS}s"

echo "=== 记录当前 dev 版本与本次耗时 ==="
printf '%s\n' "$TAG" > "$DS/dev.tag"
printf '%s\n' "$SHA" > "$DS/dev.sha"
printf '%s\n' "$TAG" >> "$DS/dev-tags.log"
{ printf '%s ' "$(date -Is)"; printf '#%s ' "$BUILD_NUMBER"; \
  printf 'l1=%ss build=%ss total=%ss changed=%s\n' \
    "$L1_SECONDS" "$BUILD_SECONDS" "$(( L1_SECONDS + BUILD_SECONDS ))" "${CHANGED:-none}"; } >> "$DS/build-timing.log"
chmod 600 "$DS/dev.tag" "$DS/dev.sha" "$DS/dev-tags.log" "$DS/build-timing.log"
echo "  dev tag: $TAG ($SHA)"

{ printf '%s\n' "$SHA"; git submodule status; } > "$DS/last-tree.txt"
chmod 600 "$DS/last-tree.txt"

echo "=== 本地 dev 镜像保留（每服务 5 个，保护 dev/staging 在用）==="
IMGS="nanoadmin nanobus nanoauth nanoprovisioner nanoworkspace nanogateway nanoportal nanoartifacts nanoagent"
PROTECT="$TAG $(grep -ohE 'dev-[0-9a-f]+' "$DS/stg.env" 2>/dev/null | sort -u | tr '\n' ' ')"
KEEP=$(grep -E '^dev-' "$DS/dev-tags.log" | awk '!seen[$0]++' | tail -5 | tr '\n' ' ')
echo "  keep: $KEEP"
echo "  protect: $PROTECT"
CAND=$(for i in $IMGS; do docker images "kobeyoung81/$i" --format '{{.Tag}}'; done | grep -E '^dev-[0-9a-f]{7,40}$' | sort -u)
for t in $CAND; do
  case " $KEEP $PROTECT " in *" $t "*) continue;; esac
  for i in $IMGS; do docker rmi "kobeyoung81/$i:$t" >/dev/null 2>&1 || true; done
  echo "  pruned $t"
done

echo "=== label 抽查（nanobus）==="
docker image inspect "kobeyoung81/nanobus:$TAG" | grep -A8 '"Labels"' | head -12 || true
echo "build done: $TAG (no push)"
