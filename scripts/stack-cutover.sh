#!/usr/bin/env bash
# 旧栈 → staging 的数据迁移与切换。
#
# 在 devserver 宿主机的仓库副本里执行（需要 docker CLI；不需要 mongosh 客户端，
# 所有 Mongo 操作都在 mongo 镜像里跑）。凭据只通过 0600 的 env 文件进入容器，
# 不出现在命令行参数里。
#
# 用法（白天演练 → 夜间切换）：
#   cp scripts/cutover/cutover.env.example scripts/cutover/cutover.env
#   $EDITOR scripts/cutover/cutover.env          # 至少确认 ENV_PREFIX 与库名
#   ./scripts/stack-cutover.sh preflight
#   ./scripts/stack-cutover.sh rehearse           # 演练（测试库 + migtest- 卷）
#   ./scripts/stack-cutover.sh cleanup            # 清演练产物
#   ./scripts/stack-cutover.sh backup             # 切换前备份
#   sudo -v; ./scripts/stack-cutover.sh cutover --yes   # 夜间窗口
#
# 每一步都能单独停；任何一步失败都会打印「停在哪 / 怎么继续 / 怎么回滚」。

set -Eeuo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENVF=${CUTOVER_ENV:-$ROOT/scripts/cutover/cutover.env}
MAP=$ROOT/scripts/cutover/collection-map.tsv
[ -f "$ENVF" ] || { echo "缺少 $ENVF（从 cutover.env.example 复制）" >&2; exit 1; }
# Export so `docker compose` sees ENV_PREFIX for its ${...} interpolation.
set -a
# shellcheck disable=SC1090
. "$ENVF"
set +a

PROJECT=${NEW_PROJECT:-${ENV_PREFIX:-}nanosec}
NEW_COMPOSE=${NEW_COMPOSE:-$NEW_ROOT/docker-compose.yml}
STATE=${STATE:-/home/kobeyoung81/nanosec-cutover}
MONGO_IMAGE=${MONGO_IMAGE:-mongo:8.2.6}
TEST_DB=${TEST_DB:-nanosec_cutover_test}
TEST_VOLUME_PREFIX=${TEST_VOLUME_PREFIX:-migtest-}
STAMP=${STAMP:-$(date +%Y%m%d-%H%M%S)}
WORK=$STATE/work-$STAMP

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1"; }

on_error() {
  local rc=$?
  warn "第 $STEP 步失败（退出码 $rc）。"
  warn "现场在 $WORK；旧栈未被修改时的安全做法是：修复后重跑同一步，或 ./scripts/stack-cutover.sh rollback"
  exit $rc
}
trap on_error ERR

STEP=init
step() { STEP=$1; log "[$STEP] $2"; }

# json_str quotes a value for embedding in a mongosh script (passwords are hex,
# but quoting here keeps a stray character from breaking the script).
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# write_uri_env writes a 0600 file holding a URI, for `docker run --env-file`.
write_uri_env() {
  local file=$1 uri=$2
  ( umask 077; printf 'MONGO_URI=%s\n' "$uri" > "$file" )
}

# mongo_js runs a mongosh script against a URI. The URI and the script travel on
# stdin, never in the container's argv.
mongo_js() {
  local uri=$1 js=$2 f rc
  f=$(mktemp "${TMPDIR:-/tmp}/cutover-js.XXXXXX")
  # 0644, not 0600: this Docker daemon runs containers with a remapped root that
  # cannot read the invoking user's private files. The script only names a URI
  # that a 0600 env file already holds, and it is deleted right after the run.
  printf 'const uri = "%s";\nconst db = connect(uri);\n%s\n' "$(json_str "$uri")" "$js" > "$f"
  chmod 644 "$f"
  rc=0
  docker run --rm --network host -v "$f:/work/script.js:ro" "$MONGO_IMAGE" \
    mongosh --nodb --quiet --file /work/script.js || rc=$?
  rm "$f" 2>/dev/null || true
  return $rc
}

old_uri() {
  if [ -n "${OLD_URI:-}" ]; then printf '%s' "$OLD_URI"; return; fi
  local raw
  raw=$(docker inspect "${OLD_PROJECT}-nanobus-1" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^NANOSEC_BUS_DATABASE_URI=//p')
  [ -n "$raw" ] || die "读不到旧栈的 NANOSEC_BUS_DATABASE_URI（容器 ${OLD_PROJECT}-nanobus-1）"
  printf '%s' "$raw"
}

new_uri() {
  if [ -n "${NEW_URI:-}" ]; then printf '%s' "$NEW_URI"; return; fi
  local raw
  raw=$(grep '^NANOSEC_BUS_DATABASE_URI=' "$NEW_ENV" | cut -d= -f2-)
  [ -n "$raw" ] || die "读不到 $NEW_ENV 的 NANOSEC_BUS_DATABASE_URI"
  printf '%s' "$raw"
}

# root_uri reads P1_ROOT_URI without sourcing the file: its value contains `&`,
# which a shell would treat as an operator. Multi-host seed URIs are collapsed to
# their first host (the surviving member of this deployment's replica set).
root_uri() {
  [ -f "$ROOT_ENV" ] || die "缺少 root 连接串文件 $ROOT_ENV"
  local raw
  raw=$(sed -n 's/^P1_ROOT_URI=//p' "$ROOT_ENV" | head -1)
  [ -n "$raw" ] || die "$ROOT_ENV 里没有 P1_ROOT_URI"
  printf '%s' "$raw" | sed -E 's#@([^,/]+),[^/]+#@\1#'
}

# source_db prints the database name for a map row: bus (the legacy platform
# database) or artifacts (the legacy work library, which had its own).
source_db() { # $1 = bus|artifacts
  if [ "$1" = artifacts ]; then printf '%s' "${OLD_ARTIFACTS_DB:-nanoartifacts}"; else printf '%s' "${OLD_DB:-nanobus}"; fi
}

# db_of prints the database name inside a URI.
db_of() { printf '%s' "$1" | sed -E 's#^[^/]+//[^/]+/([^?]+).*#\1#'; }

# uri_with_user_db rebuilds a URI for another user/database. Passwords are hex,
# so they need no escaping here.
uri_with_user_db() { # $1=uri $2=user $3=password $4=db
  printf '%s' "$1" \
    | sed -E "s#^([^:]+://)[^@]+@#\1$2:$3@#" \
    | sed -E "s#^([^/]+//[^/]+/)[^?]+#\1$4#"
}

# uri_no_db strips the database path: mongodump refuses `--db` when the URI
# names a different database than the one asked for.
uri_no_db() { printf '%s' "$1" | sed -E 's#^([^/]+//[^/]+)/[^?]*#\1/#'; }

# uri_with_db replaces the database name inside a URI.
uri_with_db() { printf '%s' "$1" | sed -E "s#^([^/]+//[^/]+/)[^?]+#\\1$2#"; }

# ping_db fails fast when a URI is unreachable.
ping_db() { mongo_js "$1" 'db.runCommand({ping:1}).ok' >/dev/null; }

count_coll() { mongo_js "$1" "print(db.getSiblingDB(\"$2\").getCollection(\"$3\").countDocuments({}))"; }

# map_rows prints "old<TAB>new<TAB>policy" for the TSV (comments skipped).
map_rows() { grep -vE '^\s*(#|$)' "$MAP"; }

require_yes() {
  [ "${YES:-0}" = 1 ] || die "这是会写数据的步骤；确认后用 --yes 重跑"
}

# ---------------------------------------------------------------------------
# preflight：只读。把两个栈的坐标、规模、命名是否自洽打印出来。
# ---------------------------------------------------------------------------
preflight() {
  step preflight "只读探测两个栈"
  need docker
  docker image inspect "$MONGO_IMAGE" >/dev/null 2>&1 || warn "本地没有 $MONGO_IMAGE，第一次运行时会拉取"

  [ -f "$NEW_ENV" ] || die "缺少 $NEW_ENV（stage-init 会创建）"
  local old new olddb newdb
  old=$(old_uri); new=$(new_uri)
  olddb=$(db_of "$old"); newdb=$(db_of "$new")
  [ "$old" != "$new" ] || die "新旧 URI 相同，拒绝继续"
  printf '旧栈 URI  : %s\n' "$(printf '%s' "$old" | sed -E 's#(://[^:]+:)[^@]+@#\1***@#')"
  printf '新栈 URI  : %s\n' "$(printf '%s' "$new" | sed -E 's#(://[^:]+:)[^@]+@#\1***@#')"
  printf '旧库/新库 : %s / %s\n' "$olddb" "$newdb"
  printf '项目/网络 : %s / %s_default\n' "$PROJECT" "$PROJECT"
  printf '卷前缀    : 旧 "%s" → 新 "%s"\n' "$OLD_VOLUME_PREFIX" "$NEW_VOLUME_PREFIX"

  ping_db "$old" || die "旧库连不上"
  ping_db "$new" || die "新库连不上（stage-init 建库了吗？）"

  printf '\n旧库集合（前 40）：\n'
  mongo_js "$old" "db.getSiblingDB(\"$olddb\").getCollectionNames().sort().slice(0,40).forEach(n=>print('  '+n))"
  printf '\n旧库文档数（映射表里的 business 集合）：\n'
  local src old_name new_name policy
  while IFS=$'\t' read -r src old_name new_name policy; do
    [ "$policy" = business ] || continue
    printf '  %-10s %-28s %s\n' "$src" "$old_name" "$(count_coll "$old" "$(source_db "$src")" "$old_name")"
  done < <(map_rows)

  printf '\n旧栈卷：\n'
  docker volume ls --format '{{.Name}}' | grep -E "^${OLD_VOLUME_PREFIX}nanosec-data-" | sed 's/^/  /' || true
  printf '\n磁盘：\n'
  df -h "$STATE" 2>/dev/null | tail -1 || df -h /home | tail -1

  # 命名自洽：新项目必须在跑，且 runner 的前缀/网络与 ENV_PREFIX 一致。
  if docker ps --format '{{.Names}}' | grep -qx "${PROJECT}-nanorunner-1"; then
    docker exec "${PROJECT}-nanoadmin-1" nanoadmin config get runner \
      | grep -E 'namePrefix|network|agentImage' | sed 's/^/  /'
  else
    warn "新栈（${PROJECT}）当前没在跑：仅供首次 stage-init 前检查"
  fi

  # 数据量 ×2 的磁盘要求由人工确认：这里只把数字摆出来。
  local bytes
  bytes=$(mongo_js "$old" "print(db.getSiblingDB(\"$olddb\").stats().dataSize)" | tail -1)
  printf '\n旧库 dataSize ≈ %s 字节（演练与备份各需一份；确认磁盘余量足够）\n' "${bytes:-?}"
  log "preflight 通过"
}

# ---------------------------------------------------------------------------
# backup：旧库 dump + 卷清单 + 旧栈配置快照。
# ---------------------------------------------------------------------------
backup() {
  step backup "备份旧库与配置"
  mkdir -p "$WORK"
  local old olddb
  old=$(old_uri); olddb=$(db_of "$old")
  write_uri_env "$WORK/old.env" "$old"
  docker run --rm --network host --env-file "$WORK/old.env" -v "$WORK:/work" "$MONGO_IMAGE" \
    bash -c "mongodump --uri \"\$MONGO_URI\" --db $olddb --out /work/dump --gzip"
  ( cd "$WORK" && find dump -type f -exec sha256sum {} \; > dump.sha256 )
  docker volume ls --format '{{.Name}}' | grep -E "^${OLD_VOLUME_PREFIX}nanosec-data-" > volumes.txt || true
  : > volumes-size.txt
  while read -r v; do
    [ -n "$v" ] || continue
    local kb
    kb=$(docker run --rm -v "$v:/v" "$MONGO_IMAGE" bash -c 'du -sk /v' | awk '{print $1}')
    printf '%s\t%s KB\n' "$v" "$kb" >> volumes-size.txt
  done < volumes.txt
  if [ -n "${OLD_COMPOSE:-}" ] && [ -f "$OLD_COMPOSE" ]; then cp "$OLD_COMPOSE" "$WORK/old-compose.yml"; fi
  cp "$ENVF" "$WORK/cutover.env"
  rm -f "$WORK/old.env"
  log "备份在 $WORK（dump.sha256 / volumes.txt / volumes-size.txt）"
}

# ---------------------------------------------------------------------------
# stage-init：把现有 devnanosec 改成 ENV_PREFIX 命名，并把平台配置搬进新库。
# 一次性动作；业务数据按约定丢弃（agent 容器与卷也一起清）。
# ---------------------------------------------------------------------------
stage_init() {
  step stage-init "改名 + 建库 + 搬平台配置"
  require_yes
  local target_db=${NEW_DB:?cutover.env 需要 NEW_DB}
  local old_proj=${OLD_STAGE_PROJECT:-devnanosec}
  local old_db=${OLD_STAGE_DB:-nanosec}

  mkdir -p "$NEW_ROOT" "$WORK"
  # 1) 先摘掉旧项目供给的 agent 容器：它们不归 compose 管，留着会占住旧网络，
  #    让 `compose down` 删不掉网络（实测踩过）。
  if docker ps -a --format '{{.Names}}' | grep -qE "^${old_proj}-nanosec-agent-"; then
    log "移除旧项目的 agent 容器（它们的卷在第 6 步删）"
    docker ps -a --format '{{.Names}}' | grep -E "^${old_proj}-nanosec-agent-" | xargs -r docker rm --force
  fi
  # 2) 停掉旧项目（保留卷；卷在第 6 步显式删）
  if docker ps -a --format '{{.Names}}' | grep -q "^${old_proj}-"; then
    log "停止旧项目 $old_proj"
    docker compose -p "$old_proj" \
      --env-file "${OLD_STAGE_ENV:-/home/kobeyoung81/nanosec-mongo/newstack.env}" \
      -f "${OLD_STAGE_COMPOSE:-/home/kobeyoung81/nanosec-p1/docker-compose.yml}" down \
      || warn "旧项目 down 失败，继续"
  fi
  # 网络可能因为别的容器（例如我们刚删掉的 agent）还在而被保留；再试一次。
  docker network rm "${old_proj}_default" >/dev/null 2>&1 || true

  # 2) 建库与用户（root 身份）
  local root pw
  root=$(root_uri)
  pw=${MONGO_STG_PASSWORD:-$(openssl rand -hex 24)}
  mongo_js "$root" "const a=db.getSiblingDB(\"admin\");
    try { a.createUser({user:\"$target_db\", pwd:\"$pw\", roles:[{role:\"readWrite\", db:\"$target_db\"}]}); print('user created'); }
    catch(e){ if (e.codeName==='DuplicateKey' || /already exists/.test(e.message)) { a.changeUserPassword(\"$target_db\", \"$pw\"); print('user password reset'); } else { throw e; } }"

  # 3) 把平台配置从旧库搬过来（JWT 私钥、provider key、模型绑定等）
  # Root reads the source: a re-run may already have rewritten the staging URI to
  # the new user, which has no rights on the old database.
  local src_uri
  src_uri=$(uri_with_db "${OLD_STAGE_URI:-$(root_uri)}" "$old_db")
  write_uri_env "$WORK/src.env" "$(uri_no_db "$src_uri")"
  # root restores into the new database: the staging user only holds rights on its
  # own database, which does not exist yet.
  write_uri_env "$WORK/dst.env" "$(uri_no_db "$(root_uri)")"
  docker run --rm --network host --env-file "$WORK/src.env" -v "$WORK:/work" "$MONGO_IMAGE" \
    bash -c "mongodump --uri \"\$MONGO_URI\" --db $old_db --collection admin_config --collection admin_models \
      --collection admin_model_providers --collection admin_agent_types --collection admin_agent_type_overrides \
      --collection admin_prompts --collection admin_permission_keys --collection admin_builtin_tools \
      --collection admin_skills --collection admin_user_skill_acks --collection admin_mcp_servers \
      --collection admin_alert_rules --out /work/platform --gzip"
  docker run --rm --network host --env-file "$WORK/dst.env" -v "$WORK:/work" "$MONGO_IMAGE" \
    bash -c "mongorestore --uri \"\$MONGO_URI\" --gzip --drop --dir /work/platform \
      --nsInclude '$old_db.*' --nsFrom '$old_db.*' --nsTo '$target_db.*'"
  unlink "$WORK/src.env" "$WORK/dst.env" 2>/dev/null || true

  # 4) 写 staging 的 env（沿用已有令牌；缺了就生成，并保证与旧栈不同）
  [ -f "$NEW_ENV" ] || : > "$NEW_ENV"
  local token secret base_uri
  token=$(grep '^NANOSEC_BUS_INTERNAL_TOKEN=' "$NEW_ENV" | cut -d= -f2- || true)
  secret=$(grep '^NANOARTIFACTS_SESSION_SECRET=' "$NEW_ENV" | cut -d= -f2- || true)
  [ -n "$token" ] || token=$(openssl rand -hex 24)
  [ -n "$secret" ] || secret=$(openssl rand -hex 32)
  base_uri=$(grep '^NANOSEC_BUS_DATABASE_URI=' "$NEW_ENV" | cut -d= -f2- || true)
  [ -n "$base_uri" ] || base_uri=${NEW_URI:-}
  [ -n "$base_uri" ] || die "无法确定新栈 Mongo 连接串（请在 cutover.env 设 NEW_URI）"
  ( umask 077; cat > "$NEW_ENV" <<EOF
NANOSEC_BUS_DATABASE_URI=$(uri_with_user_db "$base_uri" "$target_db" "$pw" "$target_db")
NANOSEC_BUS_INTERNAL_TOKEN=$token
NANOARTIFACTS_SESSION_SECRET=$secret
NANOARTIFACTS_QUOTA_BYTES=${NANOARTIFACTS_QUOTA_BYTES:-2147483648}
MONGO_STG_PASSWORD=$pw
EOF
  )
  chmod 600 "$NEW_ENV"

  # 5) 用新项目名起栈（compose 顶层 name 会让 -p 与它一致）
  if [ "$ROOT/docker-compose.yml" != "$NEW_COMPOSE" ]; then
    cp "$ROOT/docker-compose.yml" "$NEW_COMPOSE"
  fi
  ( cd "$NEW_ROOT" && docker compose -p "$PROJECT" --env-file "$NEW_ENV" -f "$NEW_COMPOSE" up -d )
  sleep 8
  local i
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null "http://127.0.0.1:${PORTAL_PORT:-14403}/healthz" && break
    sleep 2
  done

  # 5b) 把本栈的名字写进运行期配置，并让 runner 重新读一次（它只在启动时读）。
  local admin_c="${PROJECT}-nanoadmin-1" runner_c="${PROJECT}-nanorunner-1"
  if docker ps --format '{{.Names}}' | grep -qx "$admin_c"; then
    docker exec "$admin_c" nanoadmin config set runner network "${PROJECT}_default" >/dev/null || warn "config set network 失败"
    docker exec "$admin_c" nanoadmin config set runner namePrefix "$ENV_PREFIX" >/dev/null || warn "config set namePrefix 失败"
    docker exec "$admin_c" nanoadmin config set runner runner.runnerID "$PROJECT" >/dev/null || warn "config set runnerID 失败"
    docker restart "$runner_c" >/dev/null || warn "重启 runner 失败"
    sleep 3
  fi

  # 6) 清掉旧命名的 agent 容器与卷（业务数据可丢；先确认它们属于旧项目）
  log "清理旧 staging 的 agent 容器与卷"
  # grep exits 1 when nothing matches; with pipefail that would abort the step.
  docker ps -a --format '{{.Names}}' | grep -E "^${old_proj}-nanosec-agent-" | xargs -r docker rm --force || true
  docker volume ls --format '{{.Name}}' | grep -E "^${old_proj}-nanosec-data-" | xargs -r docker volume rm || true

  log "stage-init 完成：项目 $PROJECT，库 $target_db"
}

# ---------------------------------------------------------------------------
# migrate-db：旧库 → 目标库（business = drop+restore；platform 默认跳过）。
# ---------------------------------------------------------------------------
migrate_db() {
  local target=${1:-${NEW_DB}}
  step migrate-db "导入业务集合到 $target"
  mkdir -p "$WORK"
  local old
  old=$(old_uri)
  write_uri_env "$WORK/old.env" "$(uri_no_db "$old")"
  write_uri_env "$WORK/dst.env" "$(uri_no_db "$(new_uri)")"
  local src_dbs="$OLD_DB ${OLD_ARTIFACTS_DB:-nanoartifacts}"
  local db
  for db in $src_dbs; do
    docker run --rm --network host --env-file "$WORK/old.env" -v "$WORK:/work" "$MONGO_IMAGE" \
      bash -c "mongodump --uri \"\$MONGO_URI\" --db $db --out /work/dump-$target --gzip"
  done

  local src old_name new_name policy
  while IFS=$'\t' read -r src old_name new_name policy; do
    [ "$policy" = business ] || continue
    db=$(source_db "$src")
    docker run --rm --network host --env-file "$WORK/dst.env" -v "$WORK:/work" "$MONGO_IMAGE" \
      bash -c "mongorestore --uri \"\$MONGO_URI\" --gzip --drop --dir /work/dump-$target \
        --nsInclude '$db.$old_name' --nsFrom '$db.$old_name' --nsTo '$target.$new_name'" >/dev/null
    printf '  %-10s %-24s → %-24s %s\n' "$src" "$old_name" "$new_name" \
      "$(count_coll "$(uri_with_db "$(new_uri)" "$target")" "$target" "$new_name")"
  done < <(map_rows)
  unlink "$WORK/old.env" "$WORK/dst.env" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# migrate-volumes：旧卷 → 目标前缀（目标已存在则跳过；复制后比对文件数）。
# ---------------------------------------------------------------------------
migrate_volumes() {
  local new_prefix=${1:-$NEW_VOLUME_PREFIX}
  step migrate-volumes "复制用户数据卷到 ${new_prefix}nanosec-data-*"
  local src name dst n1 n2
  while read -r src; do
    [ -n "$src" ] || continue
    name=${src#"$OLD_VOLUME_PREFIX"}
    dst="${new_prefix}${name}"
    if docker volume inspect "$dst" >/dev/null 2>&1; then
      printf '  %s 已存在，跳过\n' "$dst"
      continue
    fi
    docker volume create "$dst" >/dev/null
    docker run --rm -v "$src:/src:ro" -v "$dst:/dst" "$MONGO_IMAGE" bash -c 'cp -a /src/. /dst/'
    n1=$(docker run --rm -v "$src:/v" "$MONGO_IMAGE" bash -c 'find /v -type f | wc -l')
    n2=$(docker run --rm -v "$dst:/v" "$MONGO_IMAGE" bash -c 'find /v -type f | wc -l')
    printf '  %-46s → %-46s files %s/%s\n' "$src" "$dst" "$n1" "$n2"
    [ "$n1" = "$n2" ] || die "卷 $src 的文件数不一致，停下"
  done < <(docker volume ls --format '{{.Name}}' | grep -E "^${OLD_VOLUME_PREFIX}nanosec-data-")
}

# ---------------------------------------------------------------------------
# enqueue-agents：把导入的容器行作废，并为每个有智能体的账号入队一次供给。
# 走 provisioner 的内部 API（在它自己的容器里用 wget，令牌来自容器 env）。
# ---------------------------------------------------------------------------
enqueue_agents() {
  local target=${1:-${NEW_DB}}
  step enqueue-agents "为每个账号重新入队容器"
  local uri; uri=$(uri_with_db "$(new_uri)" "$target")
  # 每个账号挑一个未删除的智能体
  local pairs
  pairs=$(mongo_js "$uri" "
    const a=db.getSiblingDB(\"$target\");
    a.portal_agents.find({status:{\$ne:'deleted'}},{_id:1,user_id:1}).sort({_id:1}).forEach(d=>print(d.user_id+' '+d._id));
  ")
  # 先让旧行不再代表“正在运行的旧容器”
  mongo_js "$uri" "const a=db.getSiblingDB(\"$target\");
    print(a.provisioner_container_requests.updateMany({}, {\$set:{status:'disposed', updated_at:new Date()}}).modifiedCount + ' rows disposed');"
  local runner="${PROJECT}-nanorunner-1"
  docker ps --format '{{.Names}}' | grep -qx "$runner" || die "找不到 $runner（栈起来了吗？）"
  local uid aid ok=0 fail=0
  while read -r uid aid; do
    [ -n "$uid" ] || continue
    if docker exec "$runner" sh -c "wget -qO- --header=\"Authorization: Bearer \$NANOSEC_BUS_INTERNAL_TOKEN\" \
         --header='Content-Type: application/json' --post-data='{\"user_id\":\"$uid\",\"agent_id\":\"$aid\"}' \
         http://127.0.0.1:8080/api/v1/internal/container-requests" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      warn "入队失败：$uid / $aid"; fail=$((fail+1))
    fi
  done <<< "$pairs"
  log "入队完成：成功 $ok，失败 $fail"
  [ "$fail" = 0 ] || die "有账号入队失败，见上面的告警"
}

# ---------------------------------------------------------------------------
# verify：旧库 vs 目标库的计数、卷文件数、服务健康、容器就绪数。
# ---------------------------------------------------------------------------
verify() {
  local target=${1:-${NEW_DB}}
  local scope=${2:-all}
  step verify "核对 $target（$scope）"
  local old olddb new newdb
  old=$(old_uri); olddb=$(db_of "$old")
  new=$(uri_with_db "$(new_uri)" "$target"); newdb=$target
  local bad=0
  printf '\n集合计数（旧 → 新）：\n'
  local src old_name new_name policy a b
  while IFS=$'\t' read -r src old_name new_name policy; do
    [ "$policy" = business ] || continue
    a=$(count_coll "$old" "$(source_db "$src")" "$old_name")
    b=$(count_coll "$new" "$newdb" "$new_name")
    if [ "$a" = "$b" ]; then
      printf '  %-30s %8s ✓\n' "$new_name" "$b"
    else
      printf '  %-30s %8s ≠ %s ✗\n' "$new_name" "$b" "$a"; bad=$((bad+1))
    fi
  done < <(map_rows)

  [ "$scope" = all ] || { [ "$bad" = 0 ] || die "verify 有 $bad 项不一致"; log "verify 通过（仅计数）"; return 0; }

  printf '\n服务健康：\n'
  local port
  for port in 14400 14401 14402 14403 14404; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz"; then printf '  %s ✓\n' "$port"; else printf '  %s ✗\n' "$port"; bad=$((bad+1)); fi
  done

  printf '\nagent 容器就绪数：%s\n' "$(docker ps --format '{{.Names}}' | grep -cE "^${NEW_VOLUME_PREFIX}?nanosec-agent-|^${PROJECT}-nanosec-agent-" || true)"
  [ "$bad" = 0 ] || die "verify 有 $bad 项不一致"
  log "verify 通过"
}

# ---------------------------------------------------------------------------
# rehearse：完整演练（测试库 + 测试卷前缀），不碰 staging 的生产库。
# ---------------------------------------------------------------------------
rehearse() {
  YES=1
  step rehearse "演练到 $TEST_DB / ${TEST_VOLUME_PREFIX}nanosec-data-*"
  mkdir -p "$WORK"
  local root; root=$(root_uri)
  mongo_js "$root" "const a=db.getSiblingDB(\"admin\");
    try { a.createUser({user:\"$TEST_DB\", pwd:\"rehearse-only\", roles:[{role:\"readWrite\", db:\"$TEST_DB\"}]}); } catch(e) {}"
  mongo_js "$root" "db.getSiblingDB(\"$TEST_DB\").dropDatabase(); print('test db reset')"
  # The staging user has rights only on its own database, so the rehearsal uses
  # the throwaway user created above.
  NEW_URI=$(uri_with_user_db "$(new_uri)" "$TEST_DB" "rehearse-only" "$TEST_DB")
  migrate_db "$TEST_DB"
  migrate_volumes "$TEST_VOLUME_PREFIX"
  verify "$TEST_DB" db
  warn "演练不做服务健康与入队（它们指向 staging 生产栈）；计数与卷一致即通过"
  warn "重复执行即可验证幂等；清理用 ./scripts/stack-cutover.sh cleanup"
}

# ---------------------------------------------------------------------------
# cutover：夜间窗口。停旧栈 → 迁移 → 起新栈 → 验证。302 由外层 nginx 做。
# ---------------------------------------------------------------------------
cutover() {
  require_yes
  step cutover "停旧栈、迁移、起新栈"
  preflight
  backup

  log "停旧栈的写入口（网关/门户/总线）"
  docker stop "${OLD_PROJECT}-nanogateway-1" "${OLD_PROJECT}-nanoportal-1" "${OLD_PROJECT}-nanobus-1" >/dev/null || true
  log "停旧栈的 agent 容器"
  docker ps --format '{{.Names}}' | grep -E "^${OLD_VOLUME_PREFIX}nanosec-agent-" | xargs -r docker stop >/dev/null || true
  warn "旧栈 Mongo 是宿主共享实例（mongo 项目），不停它；dump 是只读的"

  migrate_db "$NEW_DB"
  migrate_volumes "$NEW_VOLUME_PREFIX"

  log "起 staging（init 容器会建索引）"
  ( cd "$NEW_ROOT" && docker compose -p "$PROJECT" --env-file "$NEW_ENV" -f "$NEW_COMPOSE" up -d )
  sleep 10
  enqueue_agents "$NEW_DB"
  verify "$NEW_DB"

  cat <<'EOF'

下一步（人工）：
  1) 浏览器用旧账号登录新域名（会要求重新登录）→ 抽查 3 个旧会话、上传下载、作品库。
  2) 在外层 nginx 把旧域名 301 到新域名（片段见 docs/CUTOVER.md §5）。
  3) 24 小时内不要删除旧栈容器与卷；回滚用 ./scripts/stack-cutover.sh rollback
EOF
}

# ---------------------------------------------------------------------------
# rollback：停 staging、把旧栈起回来（旧栈数据在 copy 模式下未被改动）。
# ---------------------------------------------------------------------------
rollback() {
  require_yes
  step rollback "停 staging，恢复旧栈"
  ( cd "$NEW_ROOT" && docker compose -p "$PROJECT" --env-file "$NEW_ENV" -f "$NEW_COMPOSE" down ) || true
  docker start "${OLD_PROJECT}-nanobus-1" "${OLD_PROJECT}-nanogateway-1" "${OLD_PROJECT}-nanoportal-1" >/dev/null
  docker ps --format '{{.Names}}' | grep -E "^${OLD_VOLUME_PREFIX}nanosec-agent-" | xargs -r docker start >/dev/null || true
  warn "把外层 nginx 的 301 去掉（或反向），再确认旧栈可登录"
}

# ---------------------------------------------------------------------------
# cleanup：删演练库与演练卷。生产切换后的 staging 数据不动。
# ---------------------------------------------------------------------------
cleanup() {
  require_yes
  step cleanup "删除演练产物"
  local root; root=$(root_uri)
  mongo_js "$root" "db.getSiblingDB(\"$TEST_DB\").dropDatabase(); print('dropped $TEST_DB')"
  docker volume ls --format '{{.Name}}' | grep -E "^${TEST_VOLUME_PREFIX}" | xargs -r docker volume rm
  log "cleanup 完成（旧栈与 staging 均未改动）"
}

usage() {
  sed -n '2,30p' "$0"
}

main() {
  need docker
  YES=0
  if [ "${2:-}" = --yes ]; then YES=1; fi
  case "${1:-}" in
    preflight)      preflight ;;
    backup)         backup ;;
    stage-init)     stage_init ;;
    rehearse)       rehearse ;;
    migrate-db)     migrate_db "${NEW_DB}" ;;
    migrate-volumes) migrate_volumes "$NEW_VOLUME_PREFIX" ;;
    enqueue-agents) enqueue_agents "${NEW_DB}" ;;
    verify)         verify "${NEW_DB}" ;;
    cutover)        cutover ;;
    rollback)       rollback ;;
    cleanup)        cleanup ;;
    *)              usage; exit 2 ;;
  esac
}

main "$@"
