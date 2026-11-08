#!/usr/bin/env bash
# P1 数据面合并：把新实例上的两个库（nanosec / nanoartifacts）合并成一个
# nanosec 库，集合按模块前缀改名。只动新栈（devnanosec），不碰老栈。
#
# 用法（在 devserver 宿主机上执行，按顺序）：
#   ./p1-migrate.sh backup      # 停栈 + mongodump 两个库（回滚基线）
#   ./p1-migrate.sh restore     # 按映射把两个 dump 写进 nanosec 的新名下
#   ./p1-migrate.sh cleanup     # 删掉旧名集合（搬完才删）
#   ./p1-migrate.sh cleanup     # 删掉旧名集合与临时库表
#   ./p1-migrate.sh env         # 连接串指向 nanosec 库
#   ./p1-migrate.sh role        # artifacts 用户在 nanosec 库的最小权限
#   ./p1-migrate.sh start       # 起栈（bus-init 会跑 migrate + seed）
#   ./p1-migrate.sh verify      # 只读核对
#   ./p1-migrate.sh rollback    # 停栈 → 按旧名恢复 → 恢复 env → 起栈
#
# 每一步都能单独停；backup 产出的目录在下一步开始前不会被改。

set -euo pipefail

ENVF=${ENVF:-/home/kobeyoung81/nanosec-mongo/newstack.env}
COMPOSE_DIR=${COMPOSE_DIR:-/home/kobeyoung81/docker_mounts/jenkins_home/workspace/Dev.NanoSec}
COMPOSE_FILE=$COMPOSE_DIR/docker-compose.yml
PROJECT=devnanosec
MONGO_IMAGE=${MONGO_IMAGE:-mongo:8.2.6}
STATE=/home/kobeyoung81/nanosec-mongo
DUMP=${DUMP:-$STATE/p1-dump}
STAGE=${STAGE:-$STATE/p1-stage}
ROOT_ENV=${ROOT_ENV:-$STATE/p1-root.env}

uri() { grep "^$1=" "$ENVF" | cut -d= -f2-; }
compose() { docker compose -p "$PROJECT" --env-file "$ENVF" -f "$COMPOSE_FILE" "$@"; }

# 在 mongo 镜像里跑一段脚本：凭据只从 --env-file 进容器环境，不落在 argv 里。
run_mongo() {
  local extra=()
  [ -f "$ROOT_ENV" ] && extra+=(-v "$ROOT_ENV:/root.env:ro")
  docker run --rm --network host --env-file "$ENVF" \
    -v "$DUMP:/dump" -v "$STAGE:/stage" "${extra[@]}" "$MONGO_IMAGE" bash -c "$1"
}

# mongorestore 认的是「dump 根 → 库目录 → 集合」，而 mongodump --out=X 会多套一层
# X/<库>。把两层摊平成 STAGE/<源库>/<集合>，并去掉库名后的 URI（带着库名时
# mongorestore 会以为是单库恢复，直接跳过库目录）。
stage_dumps() {
  mkdir -p "$STAGE"
  docker run --rm -v "$DUMP:/dump:ro" -v "$STAGE:/stage" "$MONGO_IMAGE" bash -c \
    'mkdir -p /stage/nanosec /stage/nanoartifacts && cp -a /dump/bus/nanosec/. /stage/nanosec/ && cp -a /dump/artifacts/nanoartifacts/. /stage/nanoartifacts/'
}

# root 连接串落在一个 0600 文件里、挂进容器再读，不进 argv。
write_root_env() {
  umask 077
  printf 'P1_ROOT_URI=%s\n' "$(root_uri)" > "$ROOT_ENV"
}

root_uri() {
  printf 'mongodb://root:%s@192.168.9.90:27020,192.168.9.90:27021,192.168.9.90:27022/?authSource=admin&replicaSet=rs0' \
    "$(grep '^root=' "$STATE/credentials.txt" | cut -d= -f2-)"
}

restore_uri() { printf '%s' "$(uri NANOSEC_BUS_DATABASE_URI)" | sed -E 's#^(mongodb://[^/]+)/[^?]*#\1/#'; }

# 用 root 身份跑一段 JS：密码从 credentials.txt 读，经 stdin 送进容器。
mongo_root() {
  local js=$1
  { printf 'const rootUri = "mongodb://root:%s@192.168.9.90:27020,192.168.9.90:27021,192.168.9.90:27022/?authSource=admin&replicaSet=rs0";\nconst m = connect(rootUri);\n' \
      "$(grep '^root=' "$STATE/credentials.txt" | cut -d= -f2-)"; printf '%s\n' "$js"; } \
    | docker exec -i nanosec-mongo-1 mongosh --quiet --nodb
}

ns_pairs() { # $1=源库 $2=目标库，其余为 "旧 新" 对
  local from=$1 to=$2 pair
  shift 2
  for pair in "$@"; do
    printf -- '--nsFrom "%s.%s" --nsTo "%s.%s" ' "$from" "${pair%% *}" "$to" "${pair##* }"
  done
}

BUS_PAIRS=(
  "users auth_users"
  "oauth_providers auth_oauth_providers"
  "refresh_tokens auth_refresh_tokens"
  "git_browser_shortcuts auth_git_shortcuts"
  "user_secrets auth_secrets"
  "system_flags sys_flags"
  "agent_types admin_agent_types"
  "agent_type_overrides admin_agent_type_overrides"
  "permission_keys admin_permission_keys"
  "models admin_models"
  "model_providers admin_model_providers"
  "service_config_items admin_config"
  "audit_log admin_audit_log"
  "alert_rules admin_alert_rules"
  "builtin_tools admin_builtin_tools"
  "mcp_servers admin_mcp_servers"
  "skills admin_skills"
  "user_skill_acks admin_user_skill_acks"
  "session_head_prompts admin_prompts"
  "agents portal_agents"
  "agent_sessions portal_sessions"
  "agent_groups portal_agent_groups"
  "binding_agent_preferences portal_binding_preferences"
  "inbound_queue bus_inbound_queue"
  "outbound_queue bus_outbound_queue"
  "wechatkf_sync_state bus_wechatkf_sync_state"
  "container_requests provisioner_container_requests"
  "runners provisioner_runners"
  "counters sys_counters"
)

ART_PAIRS=(
  "artifacts artifacts"
  "artifact_versions artifacts_versions"
  "artifact_grants artifacts_grants"
  "spaces artifacts_spaces"
  "space_grants artifacts_space_grants"
  "nodes artifacts_nodes"
  "uploads artifacts_uploads"
  "fs.files artifacts_fs.files"
  "fs.chunks artifacts_fs.chunks"
)

need_dump() {
  [ -d "$DUMP/bus/nanosec" ] && [ -d "$DUMP/artifacts/nanoartifacts" ] \
    || { echo "缺少 $DUMP 下的 dump，先跑 backup" >&2; exit 1; }
}

case "${1:-}" in
  backup)
    echo "== 停栈（项目 $PROJECT）"
    compose stop
    mkdir -p "$DUMP"
    run_mongo '
      set -e
      rm -rf /dump/bus /dump/artifacts
      mongodump --uri="$NANOSEC_BUS_DATABASE_URI" --out=/dump/bus
      mongodump --uri="$NANOARTIFACTS_MONGO_URI" --out=/dump/artifacts
    '
    echo "== 备份完成：$(du -sh "$DUMP" | cut -f1)"
    ;;

  restore)
    need_dump
    stage_dumps
    write_root_env
    echo "== 清掉上一次可能的残留（临时库 + 目标库里已有的目标集合）"
    mongo_root '
      for (const name of ["p1_bus_tmp", "p1_art_tmp"]) { m.getSiblingDB(name).dropDatabase(); }
      const d = m.getSiblingDB("nanosec");
      const re = /^(auth_|admin_|bus_|portal_|provisioner_|sys_)|^artifacts/;
      d.getCollectionNames().filter(n => re.test(n) || n === "schema_migrations").forEach(n => d.getCollection(n).drop());
    '
    # 先按原名整库恢复进临时库：mongorestore 的 --nsFrom/--nsTo 对 GridFS 的
    # fs.files / fs.chunks 有特判（认成 bucket），逐集合改名反而会漏。
    echo "== 恢复到临时库"
    run_mongo "set -e; B=\"\$(cut -d= -f2- /root.env)\"; mongorestore --uri=\"\$B\" --nsFrom 'nanosec.*' --nsTo 'p1_bus_tmp.*' /stage"
    run_mongo "set -e; B=\"\$(cut -d= -f2- /root.env)\"; mongorestore --uri=\"\$B\" --nsFrom 'nanoartifacts.*' --nsTo 'p1_art_tmp.*' /stage"
    echo "== 逐集合改名进 nanosec"
    js="const moves = ["
    for pair in "${BUS_PAIRS[@]}"; do js+="[\"p1_bus_tmp.${pair%% *}\",\"nanosec.${pair##* }\"],"; done
    for pair in "${ART_PAIRS[@]}"; do js+="[\"p1_art_tmp.${pair%% *}\",\"nanosec.${pair##* }\"],"; done
    js+="];"
    js+=' let ok = 0, skip = 0; for (const [from, to] of moves) { const src = m.getSiblingDB(from.split(".")[0]); if (!src.getCollectionNames().includes(from.split(".").slice(1).join("."))) { print("missing " + from); skip++; continue; } m.getSiblingDB("admin").runCommand({ renameCollection: from, to: to, dropTarget: true }); ok++; } print("renamed " + ok + ", missing " + skip);'
    mongo_root "$js"
    echo "== 删掉临时库"
    mongo_root 'for (const name of ["p1_bus_tmp", "p1_art_tmp"]) { m.getSiblingDB(name).dropDatabase(); }'
    ;;

  cleanup)
    echo "== 删掉旧名集合（数据已经搬到新名下）与临时库表"
    js="const olds = ["
    for pair in "${BUS_PAIRS[@]}"; do js+="\"${pair%% *}\","; done
    js+="\"schema_migrations\",\"bus_migrations_tmp\",\"artifacts_migrations_tmp\"];"
    js+=' const d = m.getSiblingDB("nanosec"); let n = 0; for (const c of olds) { if (d.getCollectionNames().includes(c)) { d.getCollection(c).drop(); n++; } } print("dropped " + n + " old collections");'
    mongo_root "$js"
    ;;

  migrations)
    echo "== 迁移记录不搬：manifest 是声明式的，首次启动会重放一遍（建已存在的索引是 no-op），"
    echo "   并把 bus / artifacts 各自的记录以 <service>:<name> 写进 sys_migrations。"
    echo "   启动后用 verify 检查 sys_migrations 的分组计数与 migrate 的 pending 数。"
    ;;

  env)
    echo "== newstack.env：两个 URI 都指向 nanosec 库，且共用同一个凭据（P1 决策）"
    cp -a "$ENVF" "$ENVF.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$ENVF" <<'PYENV'
import sys
path = sys.argv[1]
values = {}
for line in open(path):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        values[k] = v
values["NANOARTIFACTS_MONGO_URI"] = values["NANOSEC_BUS_DATABASE_URI"]
with open(path, "w") as f:
    for k, v in values.items():
        if k in ("NANOSEC_BUS_DATABASE_URI", "NANOARTIFACTS_MONGO_URI", "NANOARTIFACTS_SESSION_SECRET", "NANOSEC_BUS_INTERNAL_TOKEN"):
            f.write(f"{k}={v}\n")
PYENV
    grep -E '^(NANOSEC_BUS_DATABASE_URI|NANOARTIFACTS_MONGO_URI)=' "$ENVF" \
      | sed -E 's#(mongodb://[^:]+:)[^@]*@#\1***@#'
    echo "== 注意：Dev.NanoSec job 里那两行 echo 仍是 /nanoartifacts + nanoartifacts 用户（root 所有），需同步改"
    ;;

  role)
    echo "== artifacts 用户在 nanosec 库的最小权限（只覆盖 artifacts* 与 sys_migrations）"
    mongo_root '
      const d = m.getSiblingDB("nanosec");
      const mine = d.getCollectionNames().filter(n => n === "artifacts" || n.startsWith("artifacts_"));
      const actions = ["find","insert","update","remove","createIndex","dropIndex"];
      const privileges = mine.map(n => ({ resource: { db: "nanosec", collection: n }, actions }))
        .concat([{ resource: { db: "nanosec", collection: "sys_migrations" }, actions: ["find","insert","update"] }]);
      try { d.dropRole("artifactsWriter"); } catch (e) {}
      d.createRole({ role: "artifactsWriter", privileges, roles: [] });
      m.getSiblingDB("nanoartifacts").grantRolesToUser("nanoartifacts", [{ role: "artifactsWriter", db: "nanosec" }]);
      print("collections covered: " + mine.length);
    '
    ;;

  start)
    echo "== 起栈"
    compose up -d
    sleep 20
    compose ps
    compose logs --tail=30 bus-init || true
    ;;

  verify)
    run_mongo '
      mongosh "$NANOSEC_BUS_DATABASE_URI" --quiet --eval "
        const d = db.getSiblingDB(\"nanosec\");
        const names = d.getCollectionNames().sort();
        const allowed = /^(auth_|admin_|bus_|portal_|provisioner_|sys_|artifacts)/;
        print(\"collections: \" + names.length + \" stray: \" + JSON.stringify(names.filter(n => !allowed.test(n))));
        print(names.map(n => n + \"=\" + d.getCollection(n).countDocuments({})).join(\" \"));
        print(\"migrations: \" + JSON.stringify(d.getCollection(\"sys_migrations\").aggregate([{ \$group: { _id: \"\$service\", n: { \$sum: 1 } } }]).toArray()));
        for (const [c, idx] of [[\"portal_sessions\",\"agent_updated\"],[\"auth_users\",\"email_unique\"],[\"admin_agent_types\",\"name_unique\"]]) {
          const present = names.includes(c);
          print(c + \" \" + idx + \" = \" + (present ? d.getCollection(c).getIndexes().filter(i => i.name === idx).length : \"missing collection\"));
        }
        print(\"artifacts_fs.chunks indexes = \" + (names.includes(\"artifacts_fs.chunks\") ? JSON.stringify(d.getCollection(\"artifacts_fs.chunks\").getIndexes().map(i => i.name)) : \"missing collection\"));
      "
    '
    ;;

  rollback)
    need_dump
    echo "== 回滚：停栈 → 按旧名恢复 → 恢复 env → 起栈"
    compose stop
    run_mongo '
      set -e
      mongorestore --uri="$NANOSEC_BUS_DATABASE_URI" --drop /dump/bus
      mongorestore --uri="$NANOARTIFACTS_MONGO_URI" --nsFrom "nanosec.*" --nsTo "nanoartifacts.*" --drop /dump/artifacts
    '
    latest=$(ls -t "$ENVF".bak-* | head -1)
    cp -a "$latest" "$ENVF"
    compose up -d
    echo "== 已按 $latest 恢复连接串"
    ;;

  *)
    sed -n '2,18p' "$0"
    exit 2
    ;;
esac
