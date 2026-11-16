# 生产切换手册：旧栈 → staging（`stg-nanosec`）

> 读者：夜里执行切换的运维同学。所有命令都在 **devserver 宿主机** 上跑（`ssh devserver.zwm.home`）。
> 脚本在仓库 `scripts/stack-cutover.sh`，宿主副本在 `/home/kobeyoung81/nanosec-stg/scripts/`。
> 任何一步的输出与本手册的「预期」不符，**停下**，按第 7 节处理。

## 1 前置条件（切换前一天核对）

- [ ] 宿主机磁盘剩余 ≥ 旧库数据量 × 3（演练、备份、增量各一份；`preflight` 会打印数字，当前约 300 MB 库 + 20 GB 卷）
- [ ] `docker` CLI 可用；本地有 `mongo:8.2.6` 镜像（`docker image inspect mongo:8.2.6`）
- [ ] `/home/kobeyoung81/nanosec-mongo/p1-root.env` 里有 root 连接串（0600）
- [ ] staging 已按第 2 节完成改名（`stg-nanosec` 项目 + `stg_nanosec` 库）并处于健康状态
- [ ] 旧栈的 `devmyriadmind-nanobus-1` 在跑；`preflight` 能读到它的 `NANOSEC_BUS_DATABASE_URI`
- [ ] 与用户约定停机窗口（预计 10–30 分钟，含 19 GB 卷复制约 3 分钟）
- [ ] 外层 nginx（nginxWebUI）的 301 片段已准备好（第 5 节），切换时只需粘贴

## 2 命名规则（只配一个变量）

```
ENV_PREFIX=stg-        # staging；dev- = 开发；空 = 生产
```

| 名字 | 结果（staging） |
|---|---|
| compose 项目 / 容器 | `stg-nanosec` / `stg-nanosec-<服务>-1` |
| 网络 | `stg-nanosec_default` |
| agent 容器 / 卷 | `stg-nanosec-agent-<uid>` / `stg-nanosec-data-<uid>` |
| runner 身份 | `stg-nanosec` |
| Mongo 库 / 用户 | `stg_nanosec`（`-` 换成 `_`，因为库名在 URI 里） |
| 镜像 tag | `:nanosec`（不随栈变） |

改名是一次性动作，已由 `stage-init` 完成；它做四件事：停旧项目 → 建库与用户 → 把平台集合
（`admin_*`，含 JWT 私钥与 provider key）搬进新库 → 用新项目名起栈并把 runner 的三个键写进配置。

### 2.1 staging 目前的账号状态

`stage-init` 只搬**平台配置**（`admin_*`），业务数据按约定丢弃，所以库里**没有账号**。
要在 staging 上先做内部测试，二选一：

- 直接在 `https://nanosec.kobeyoung81.cn/register` 注册一个账号（全新库里首个注册账号自动成为管理员）；
- 或者提前跑一次 `./scripts/stack-cutover.sh migrate-db`，把旧栈账号/会话导进来（等同切一半，正式切换时还会覆盖一次）。

改名前的旧库 `nanosec` 仍保留在同一个实例上（含改名前的 staging 测试数据），确认不再需要后
用 `mongosh` 手工 `dropDatabase`；脚本不自动删它。

## 3 白天演练（随时可做，不碰旧栈）

```bash
cd /home/kobeyoung81/nanosec-stg
./scripts/stack-cutover.sh preflight      # 只读：两个栈的坐标、集合计数、卷清单、磁盘
./scripts/stack-cutover.sh rehearse       # 迁到 nanosec_cutover_test + migtest- 卷前缀
./scripts/stack-cutover.sh rehearse       # 再跑一次：证明幂等
./scripts/stack-cutover.sh cleanup --yes  # 删演练库与演练卷
```

**预期**：`rehearse` 每行 `旧数量 == 新数量 ✓`，卷行显示 `files N/N`；`cleanup` 打印
`dropped nanosec_cutover_test` 与三个 `migtest-` 卷名。演练后 `preflight` 里旧库计数不变。

## 4 夜间切换（T 为开始时间）

### T-30：通知与备份

```bash
cd /home/kobeyoung81/nanosec-stg
./scripts/stack-cutover.sh backup
```

**预期**：`备份在 /home/kobeyoung81/nanosec-cutover/work-<时间戳>`，里面有 `dump/`、`dump.sha256`、
`volumes.txt`、`volumes-size.txt`、`cutover.env`。**把这行路径抄进变更单。**

### T0：执行切换

```bash
./scripts/stack-cutover.sh cutover --yes
```

脚本按顺序做：`preflight` → `backup` → 停旧栈网关/门户/总线 → 停旧 agent 容器 →
`migrate-db`（两个源库：`nanobus` 与 `nanoartifacts`）→ `migrate-volumes` → 起 staging →
`enqueue-agents` → `verify`。

**预期（逐段）**：

| 段 | 预期输出 |
|---|---|
| 停旧栈 | `docker ps` 里 `devmyriadmind-nanogateway/nanoportal/nanobus` 消失；`mongo-mongo-1` **仍在** |
| migrate-db | 每行 `bus users → auth_users 2`、`agent_sessions → portal_sessions 238`、`artifacts_fs.chunks → artifacts_fs.chunks 145` |
| migrate-volumes | 每行 `files N/N`（两个用户卷：230 与 19 GB 那份） |
| enqueue-agents | `入队完成：成功 2，失败 0` |
| verify | 所有集合 `✓`、五个端口 `✓`、`verify 通过` |

### T+10：人工验收

1. 浏览器打开 `https://nanosec.kobeyoung81.cn`，用**旧账号**登录（会要求重新登录，这是预期）。
2. 会话列表出现旧历史；随机打开 3 个旧会话，内容与旧站一致。
3. 文件面板能列目录；上传一张图片再下载；作品库能打开旧作品并预览。
4. 控制台（管理员）能打开用户/模型/审计页面。

### T+20：挂 301

见第 5 节。挂完把「旧域名 301、新域名 200」两条 curl 结果贴进变更单。

### T+30：收尾

- 旧栈保持**停止但保留**（容器、卷、库都不动）至少 7 天。
- 记录 `cutover` 打印的备份路径。

## 5 外层 nginx：旧域名 301 到新域名

在 nginxWebUI 里给 `myriadmind.kobeyoung81.cn` 的 server 块加（或替换 location `/`）：

```nginx
location / {
    return 301 https://nanosec.kobeyoung81.cn$request_uri;
}
```

保留原来的证书与 `listen 443 ssl`；**不要**删 `nanosec.kobeyoung81.cn` 的 server 块。
改完 reload，然后验收：

```bash
curl -sI https://myriadmind.kobeyoung81.cn/agent | head -3
# 预期：HTTP/2 301、location: https://nanosec.kobeyoung81.cn/agent
curl -sI https://nanosec.kobeyoung81.cn/ | head -1
# 预期：HTTP/2 200
```

## 6 回滚（10 分钟内可回到旧栈）

```bash
cd /home/kobeyoung81/nanosec-stg
./scripts/stack-cutover.sh rollback --yes
```

它会停 staging、把旧栈的总线/网关/门户与 agent 容器起回来；随后在外层 nginx 把 301 去掉（恢复原 upstream）。
**旧栈的数据在 copy 模式下从未被改动**，所以回滚不需要恢复数据库。

## 7 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `preflight` 说「旧库连不上」 | 旧栈容器名/项目名不符，或 Mongo 端口不通 | `docker inspect devmyriadmind-nanobus-1` 看 URI；确认 `192.168.9.90:27017` 可达 |
| `EACCES ... /work/script.js` | 本机 Docker 开了 userns-remap，容器内 root 读不了 0600 文件 | 脚本已用 0644 临时文件；若再出现，检查 `TMPDIR` 是否可被容器挂载 |
| `Cannot specify different database in connection URI` | URI 里带了库名又给了 `--db` | 脚本用无库 URI（`uri_no_db`）；自定义命令时同理 |
| `migrate-volumes` 报 `files N/M` 不一致 | 复制中断（磁盘满/容器被杀） | 删掉目标卷 `docker volume rm <dst>` 后重跑 `migrate-volumes` |
| `verify` 某集合 `≠` | 旧栈在 dump 之后仍有写入（没停干净） | 确认旧栈三个服务与 agent 容器都停了，再跑 `migrate-db` + `verify` |
| agent 容器起不来 | `agentImage` 或卷前缀不对 | `docker exec stg-nanosec-nanoadmin-1 nanoadmin config get runner`，三个键应为 `stg-` / `stg-nanosec_default` / `kobeyoung81/nanoagent:nanosec` |
| 登录后立刻 401 | 浏览器还拿着旧域的令牌 | 清该域名的 localStorage（`nanosec.portal.*`）再登录 |
| 301 后循环跳转 | 新域名的 server 块也写了 301 | 只让旧域名 301，新域名必须是正常 `proxy_pass` |

## 8 切换后 24 小时观察

- `docker ps` 里 `stg-nanosec-*` 全 Up；`docker logs --tail 100 stg-nanosec-nanobus-1` 无 error。
- 五个端口 `/healthz` 200：14400–14404。
- 旧栈保持停止；确认没有人把它 `docker compose up` 起来（同时挂载同一批卷会互相写）。
- 作品库预览、文件上传、Git 面板各抽查一次。

## 9 附录：映射与卷规则

- 集合映射：`scripts/cutover/collection-map.tsv`（四列：源库、旧名、新名、策略）。
  `business` = 先 drop 再导入（旧栈为准）；`platform` = **默认跳过**（staging 已有自己的
  `admin_config`/模型目录；只有明确要迁旧配置时才手工导入）。
- 源库两个：`nanobus`（平台）与 `nanoartifacts`（作品库，旧栈独立库，见
  `devmyriadmind-nanoartifacts-1` 的 `NANOARTIFACTS_MONGO_URI`）。
- 卷名规则：旧 `nanosec-data-<uid>[-<binding>]` → 新 `stg-nanosec-data-<uid>[-<binding>]`
  （由 `ENV_PREFIX` 决定；卷内文件属主用 `cp -a` 保留）。
- 队列：`bus_inbound_queue` / `bus_outbound_queue` 不迁（旧消息属于旧栈）；`refresh_tokens` 不迁（强制重登）。
