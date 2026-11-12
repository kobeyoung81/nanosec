# NanoSec
一个基于 Go 的超轻量级个人 AI 助手系统，由多个微服务组成，通过共享的 WebSocket / REST 消息总线相互通信。

[English](./README.md)

## 架构概览

```
聊天渠道（CLI / 企业微信 / 飞书 / 微信客服 / Web）
      │
      ▼
nanogateway ──HTTP + SSE──► nanobus ◄──HTTP + SSE── nanoagent（每个用户一个容器）
                              ▲
      ┌───────────────┬───────┴────────┬──────────────────┬───────────────┐
  nanoauth        nanoadmin        nanoportal       nanoprovisioner   nanoartifacts
  （身份）        （配置、目录、    （代理、分组、    （容器、runner      （作品库：
                   审计）           会话、控制台）     注册表）            HTML 作品）
```

整平台只有**一个 MongoDB 库**，每个模块按前缀独占写入：`auth_`（nanoauth）、
`admin_`（nanoadmin）、`portal_`（nanoportal）、`provisioner_`（nanoprovisioner）、
`bus_`/`sys_`（nanobus）、`artifacts*`（nanoartifacts）。一个模块只写自己的前缀，
其他模块的数据一律通过内部 HTTP 面（带共享令牌）读取。总线只负责消息。

- **nanoprotocol** — 共享契约（Go 模块，非服务）：消息信封、类型常量、各服务使用的 HTTP/SSE 客户端
- **nanobus** — 消息：按用户队列、事件流（SSE）、runner 的转发、nanoauth JWKS 的反向代理（hypervisor 隧道已归 provisioner，总线只留旧容器的回落）
- **nanogateway** — 渠道适配器（企业微信 / 飞书 / 微信客服 / Web 聊天 / CLI）：身份解析、出入站路由、媒体、Web 渠道的 JWT 校验
- **nanoagent** — 代理运行时（二进制名 `nanosec`，每用户一个）：多代理路由、ReAct 循环、LLM provider、工具、会话、技能、定时任务、子代理与 hypervisor
- **nanoprovisioner** — 容器供给：容器请求队列、runner 注册表，以及 Docker / Swarm / Kubernetes 三种后端与分档配额
- **nanoauth** — 身份：注册、bcrypt 口令、RS256 令牌与 JWKS、刷新票、渠道与 OAuth 链接、每用户密钥
- **nanoadmin** — 管理域：配置、代理类型与其覆盖、提示词、模型、能力、权限键、告警规则、审计
- **nanoportal** — 控制台（Go + React）：用户、代理与分组、会话、作品库的外壳、浏览器聊天
- **nanoartifacts** — 作品库：发布的自包含 HTML、版本、空间、分享与配额
- **nanoasr** — 输入框听写的本地语音识别（sherpa-onnx，按 OpenAI 兼容 provider 接入）
- **nanoui** — 微信小程序与其 Go BFF

## 仓库结构

```
nanosec/                       # 超级仓库（工作区、文档、配置、部署）
├── go.work                    # Go 工作区（九个模块，本地统一构建）
├── docker-compose.yml         # 一键启动（全部服务 + 两个 init 容器）
├── .env.example               # 数据库 URI、共享令牌、作品库 Cookie 密钥的模板
├── .gitmodules                # 子模块注册表（十一个子模块）
├── configs/                   # 配置形状示例（*.example.json, dev/）
├── docs/                      # 架构、部署与设计文档
├── scripts/                   # bump-protocol.sh, install-hooks.sh, p1-migrate.sh
├── deploy/                    # 生产部署清单
│   ├── swarm/                 #   Docker Swarm stack
│   └── k8s/                   #   Kubernetes 清单
├── nanoprotocol/              # [子模块] 共享契约库
├── nanobus/                   # [子模块] 消息总线
├── nanogateway/               # [子模块] 渠道网关
├── nanoagent/                 # [子模块] 代理运行时（二进制 nanosec）
├── nanoprovisioner/           # [子模块] 容器供给（二进制 nanorunner）
├── nanoadmin/                 # [子模块] 管理域（配置、目录、审计）
├── nanoauth/                  # [子模块] 身份服务
├── nanoportal/                # [子模块] 控制台（Go + React）
├── nanoartifacts/             # [子模块] 作品库
├── nanoasr/                   # [子模块] 本地语音识别
└── nanoui/                    # [子模块] 微信小程序 + BFF
```

每个服务子模块都有各自的 `README.md`，包含架构、配置与 CLI 参考。

## 子模块配置

本仓库使用 Git 子模块管理各服务代码，并使用 Go 工作区（`go.work`）在本地联合构建。

| 子模块路径 | 远程仓库 | 说明 |
|------------|----------|------|
| `nanoprotocol` | `../nanoprotocol.git` | 共享契约库 |
| `nanobus` | `../nanobus.git` | 消息总线 |
| `nanogateway` | `../nanogateway.git` | 渠道网关 |
| `nanoagent` | `../nanoagent.git` | 代理运行时（二进制 `nanosec`） |
| `nanoprovisioner` | `../nanoprovisioner.git` | 容器供给（二进制 `nanorunner`） |
| `nanoadmin` | `git@gitee.com:kobeyoung81/nanoadmin.git` | 管理域 |
| `nanoauth` | `../nanoauth.git` | 身份服务 |
| `nanoportal` | `../nanoportal.git` | 控制台 |
| `nanoartifacts` | `../nanoartifacts.git` | 作品库 |
| `nanoasr` | `../nanoasr.git` | 语音识别 |
| `nanoui` | `../nanoui.git` | 小程序 + BFF |

远程地址是相对路径，按超级仓库的 origin 解析。

### Go 工作区

`go.work` 将九个模块联合构建，无需发布即可在本地相互引用（`nanoasr` 与 `nanoui`
各自独立构建）：

```
go 1.26.2

use (
	./nanoportal
	./nanobus
	./nanogateway
	./nanoprotocol
	./nanoprovisioner
	./nanoagent
	./nanoauth
	./nanoartifacts
	./nanoadmin
)

replace github.com/xen0n/go-workwx/v2 v2.0.0-alpha.1 => ./nanogateway/go-workwx
```

构建工作区里的所有模块：

```bash
go build ./nanobus/... ./nanogateway/... ./nanoagent/... ./nanoprovisioner/... \
         ./nanoadmin/... ./nanoauth/... ./nanoportal/... ./nanoartifacts/...
```

> 预提交钩子（通过 `./scripts/install-hooks.sh` 安装）会校验每个子模块也能以
> `GOWORK=off` 独立构建。

## 安装

### 前置依赖

- **Go 1.25+**（工作区基于 Go 1.26.2 构建；各模块自带最低版本声明）
- **Git**，且已配置 gitee.com 的 SSH 访问（`git@gitee.com:kobeyoung81/...`）
- **Docker + Docker Compose v2**（容器化部署）
- 可选：Kubernetes / Swarm 部署需要 `kubectl` 或 Swarm 管理节点

### 1. 克隆仓库（含全部子模块）

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/nanosec.git
cd nanosec
```

如果已克隆但缺少子模块：

```bash
git submodule update --init --recursive
```

安装所有子模块的预提交钩子（校验独立构建）：

```bash
./scripts/install-hooks.sh
```

> **无需配置 JWT 密钥。** `nanoauth` 在首次启动时自动生成 RSA 密钥对并存入平台配置
> （`admin_config`，组件 `auth`，键 `jwtPrivateKey`/`jwtPublicKey`），因此不需要生成
> 或挂载任何密钥文件/机密。

### 2. 准备一个 MongoDB

平台只有**一个**数据库。多个服务各自持连接，但每个只写自己的前缀（见上面的架构概览），
所以数据库 URI 是全栈共享的那一个设置。Compose 会从 shell 环境变量或项目 `.env`
文件读取它：

```bash
cp .env.example .env    # 然后修改 NANOSEC_BUS_DATABASE_URI=...
```

也可以直接导出这些必需值：

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
export NANOARTIFACTS_SESSION_SECRET="$(openssl rand -hex 32)"
```

URI 必须在路径里写明库名（上面是 `/nanosec`）；单节点副本集就够了。这三个值在
`docker-compose.yml` 里都没有兜底（`:?`），缺少任何一个栈都会拒绝启动。

### 3. 启动整个栈

```bash
docker compose up -d
```

启动的服务：

| 服务 | 宿主端口 | 用途 |
|------|----------|------|
| `nanobus` | 14400 → 9000 | 消息：REST、SSE、隧道回落、JWKS 反向代理 |
| `nanoauth` | 14401 → 8081 | 身份：注册、令牌、JWKS |
| `nanogateway` | 14402 → 8080 | 渠道适配器；Web 聊天通道由门户同源代理 |
| `nanoportal` | 14403 → 80 | 控制台（并通过它的 nginx 代理网关的 Web 通道与作品库） |
| `nanoadmin` | 14404 → 8080 | 配置与各类目录 |
| `nanoartifacts` | – | 作品库（经门户的 `/nanoartifacts/` 访问） |
| `nanoasr` | – | 本地语音识别（由总线调用） |
| `nanorunner` | – | 容器供给与 hypervisor 隧道（需要宿主机的 `docker.sock`） |

`admin-init` 先跑（应用自己的清单，再执行 `config`、`permissions`、`agent-types`、
`prompts`、`skills`、`mcp` 六个 seed），随后 `bus-init` 应用自己的清单，最后各服务启动。
**代理镜像不会随 `up` 启动** —— 它是 provisioner 为每个用户启动的镜像，位于 `agent`
profile 下。需要时单独构建：

```bash
docker compose build nanosec
```

两个首次部署的注意点：

- **第一个管理员**：门户 <http://localhost:14403> 上**第一个注册的账号**自动成为管理员
  （配置项 `auth.firstUserIsAdmin`，默认开；公网可注册时请先关掉并手工指定）。
  规则跑在 `nanoauth` 里、紧邻它修改的账号，且一次安装只触发一次（原子认领）。
- **第一个模型**：在门户 Models 页添加服务商与模型后，点该模型的「下发到内置类型」——
  否则智能体类型没有可用模型，agent 会反复重启并在日志里报
  `no model is assigned to agent type ...`。下发只补空默认，已有默认不会被改。

### 4. 配置通道与代理

服务启动时从 admin 模块（`admin_config`，由 `nanoadmin config seed` 初始化，走 HTTP）加载配置。
可在门户的 **Configs** 页面修改，或使用 CLI：

```bash
# 启用 CLI 通道（快速冒烟测试）
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.enabled true
docker compose exec nanoadmin nanoadmin config set gateway channels.cli.userID alice

# 设置代理的 LLM API Key
docker compose exec nanoadmin nanoadmin config set agent provider.apiKey sk-...
docker compose exec nanoadmin nanoadmin config set agent provider.baseUrl https://api.openai.com/v1
docker compose exec nanoadmin nanoadmin config set agent provider.defaultModel gpt-4o

# 查看当前值
docker compose exec nanoadmin nanoadmin config get gateway
docker compose exec nanoadmin nanoadmin config get agent
```

> 若配置里没有启用任何通道，`nanogateway` 会以 “no channels enabled” 退出。
> **Web 聊天通道默认启用**（`channels.web.enabled=true`，由 `nanoadmin config seed` 写入），
> 在 compose 网络内监听 `8080`、发布到宿主机 `14402`；门户也会同源代理它供聊天页使用。

### 5. 试运行

打开门户 **http://localhost:14403** 注册：全新安装的**第一个账号**会成为管理员，同时
得到一个默认代理与一条容器请求，容器起来后 **Chat** 即可用。或通过 CLI 通道聊天：

```bash
docker compose run --rm nanogateway --bus-url http://nanobus:9000 --message "Hello"
```

### 不使用 Docker 的独立运行

自行启动 MongoDB 后，从工作区构建并运行各二进制。凡是访问存储的命令都读同一个
`NANOSEC_BUS_DATABASE_URI`：

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanosec?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"

# 1. 应用清单（即两个 init 容器做的事，按序执行）
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin migrate up

# 2. 写入平台默认值与目录（admin-init 会跑全套）
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanoadmin/cmd/nanoadmin permissions seed
go run ./nanoadmin/cmd/nanoadmin agent-types seed
go run ./nanoadmin/cmd/nanoadmin prompts seed
go run ./nanoadmin/cmd/nanoadmin skills seed
go run ./nanoadmin/cmd/nanoadmin mcp seed

# 3. 总线（消息）
go run ./nanobus/cmd/nanobus

# 4. 管理域（配置与目录）
NANOSEC_ADMIN_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoadmin/cmd/nanoadmin

# 5. 身份（自己的集合；首次启动把 JWT 密钥对写进平台配置）
NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoauth/cmd/nanoauth

# 6. 控制台（代理、分组、会话投影与前端）
NANO_PORTAL_BUS_URL="http://localhost:9000" \
  NANOSEC_ADMIN_URL="http://localhost:14404" \
  NANOPORTAL_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoportal/server/cmd/nanoportal

# 7. 网关（CLI 通道；先在配置里启用）
NANOSEC_GATEWAY_BUS_URL="http://localhost:9000" \
  go run ./nanogateway/cmd/nanogateway

# 8. 容器供给（需要 Docker；每用户一个代理容器）
NANOSEC_PROVISIONER_MONGO_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_DATABASE_URI="$NANOSEC_BUS_DATABASE_URI" \
  NANOSEC_BUS_INTERNAL_TOKEN="$NANOSEC_BUS_INTERNAL_TOKEN" \
  go run ./nanoprovisioner/cmd/nanorunner
```

代理本身由第 8 步为你启动，每用户一个容器（`nanosec --user <id> --bus-url …`）。完整
顺序见 [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)。

## 生产部署

完整运维指南见 [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)，包括：

- **Docker Compose**（单机）—— 即本文档
- **Docker Swarm** —— `deploy/swarm/docker-stack.yml`（`runner.backend=swarm`）
- **Kubernetes** —— `deploy/k8s/*`（`runner.backend=k8s`，RBAC 见 `nanoprovisioner/deploy/k8s`）

## 环境变量配置前缀

环境变量覆盖连接层设置；运行时配置在 `admin_config` 里，由控制台（或
`nanoadmin config set`）修改。

| 服务 | 前缀 | 示例 |
|------|------|------|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_DATABASE_URI`、`NANOSEC_BUS_INTERNAL_TOKEN`、`NANOSEC_BUS_ADMIN_BASE_URL`、`NANOSEC_BUS_PORTAL_BASE_URL`、`NANOSEC_BUS_PROVISIONER_BASE_URL` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL`、`NANOSEC_ADMIN_URL`、`NANOSEC_PORTAL_URL` |
| `nanoagent` | `NANOSEC_` / `NANOSEC_AGENT_` | `NANOSEC_AGENT_BUS_URL`、`NANOSEC_ADMIN_URL`、`NANOSEC_PORTAL_URL` |
| `nanoprovisioner` | `NANOSEC_RUNNER_` / `NANOSEC_PROVISIONER_` | `NANOSEC_RUNNER_BUS_URL`、`NANOSEC_RUNNER_BACKEND`、`NANOSEC_PROVISIONER_MONGO_URI`、`NANOSEC_PROVISIONER_ADDR` |
| `nanoadmin` | `NANOSEC_ADMIN_` | `NANOSEC_ADMIN_MONGO_URI`、`NANOSEC_ADMIN_ADDR`、`NANOSEC_BUS_URL` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_MONGO_URI`、`NANOAUTH_ADDR`、`NANOAUTH_JWT_KEY_ID`、`NANOAUTH_WECHAT_APP_ID` |
| `nanoportal` | `NANO_PORTAL_` / `NANOPORTAL_` | `NANO_PORTAL_BUS_URL`、`NANOPORTAL_MONGO_URI`、`NANOSEC_ADMIN_URL` |
| `nanoartifacts` | `NANOARTIFACTS_` | `NANOARTIFACTS_MONGO_URI`、`NANOARTIFACTS_SESSION_SECRET`、`NANOARTIFACTS_QUOTA_BYTES` |
| `nanoasr` | `NANOSEC_` | `NANOSEC_ADMIN_URL`、`NANOSEC_BUS_INTERNAL_TOKEN` |
| `nanoui`（后端） | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR` |

> `NANOSEC_BUS_INTERNAL_TOKEN` 是全平台共享密钥：所有内部面（`/internal/v1/*`）只接受
> 带它的请求，未配置时直接拒绝。`NANOSEC_ADMIN_URL` 是各服务读取自己配置的地方。

## 协议变更流程

修改 nanoprotocol（新增类型、常量或变更签名）时，按以下流程：

1. 先在 nanoprotocol 提交变更
2. 运行 `./scripts/bump-protocol.sh vX.Y.Z` 打标签并更新所有消费方
3. 在各消费子模块提交 go.mod/go.sum
4. 先推送所有子模块，再推送超级仓库

## 参与贡献

1. Fork 本仓库
2. 新建 `feat/xxx` 分支
3. 提交代码
4. 发起 Pull Request
