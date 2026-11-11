# NanoSec
一个基于 Go 的超轻量级个人 AI 助手系统，由多个微服务组成，通过共享的 WebSocket / REST 消息总线相互通信。

[English](./README.md)

## 架构概览

```
用户 / 聊天平台
      │
      ▼
┌─────────────────┐   WebSocket   ┌──────────────┐   WebSocket   ┌──────────────┐
│  nanogateway    │ ◄────────────► │   nanobus    │ ◄────────────► │   nanosec    │
│  (网关服务)      │               │  (消息总线)   │               │  (AI 代理)   │
└─────────────────┘               └──────────────┘               └──────────────┘
                                          │  ▲            │  ▲
                    ┌─────────────────────┘  │            │  │ HTTP (hypervisor :9090)
                    ▼                        │            │  │ WebSocket tunnel
                MongoDB             ┌─────────────────┐   │
                                    │  nanorunner     │───┘──► Docker / Swarm / K8s
                                    │ (容器配置服务)   │
                                    └─────────────────┘

  认证:   nanoauth (OAuth2/OIDC, JWT) ── 由 nanobus 反向代理 ──► portal / gateway / miniapp
  管理:   nanoportal (React 管理后台) ── 读写总线（自身不持有数据库）
  移动端: nanoui (微信小程序 + Go BFF)
```

- **nanoprotocol** — 共享消息协议（Go 模块，非服务）：消息信封、70 个类型常量、自动重连的 WebSocket 客户端、REST/SSE 辅助
- **nanobus** — WebSocket 消息总线，也是平台**唯一持有数据库**的服务（MongoDB）：用户/代理注册、按用户消息队列、配置存储、Runner 注册、REST + SSE 接口，并反向代理 `/auth/v1/*` 到 nanoauth
- **nanogateway** — 聊天平台适配器（企业微信 / 飞书 / 微信客服 / Web 聊天 / CLI）：路由入站/出站消息、回执确认、媒体附件路由、Web 通道 JWT 校验
- **nanosec** — AI 代理运行时：多代理路由器、ReAct 循环、LLM provider、工具、会话、技能、定时任务、子代理、hypervisor HTTP 服务
- **nanorunner** — 容器配置服务：轮询总线获取容器请求，通过 Docker / Swarm / Kubernetes 后端按配额等级配置/销毁每个用户的代理容器
- **nanoauth** — OAuth2/OIDC 认证服务：注册、bcrypt 密码、RS256 JWT、JWKS 端点、刷新令牌、微信小程序登录
- **nanoportal** — Web 管理门户（Go + React）：用户/代理/配置/审计管理与浏览器聊天
- **nanoui** — 带微信小程序前端 + Go 后端（BFF）的 Web UI

## 仓库结构

```
myriadmind/                    # 超级仓库（工作区、文档、配置、部署）
├── go.work                    # Go 工作区（7 个模块，本地统一构建）
├── docker-compose.yml         # 一键启动（bus + auth + gateway + runner + portal）
├── .env.example               # 总线 Mongo URI + 共享令牌模板（复制为 .env）
├── .gitmodules                # 子模块注册表（8 个服务）
├── configs/                   # 配置形状示例（*.example.json, dev/）
├── docs/                      # 架构、PRD、部署、设计文档
├── plans/                     # 实施计划
├── scripts/                   # bump-protocol.sh, install-hooks.sh
├── deploy/                    # 生产部署清单
│   ├── swarm/                 #   Docker Swarm stack
│   └── k8s/                   #   Kubernetes 清单
├── nanoprotocol/              # [子模块] 共享协议库
├── nanobus/                   # [子模块] 消息总线服务
├── nanogateway/               # [子模块] 网关服务
├── nanosec/                   # [子模块] AI 代理服务
├── nanorunner/                # [子模块] 容器配置服务
├── nanoauth/                  # [子模块] OAuth2/OIDC 认证服务
├── nanoportal/                # [子模块] Web 管理门户
└── nanoui/                    # [子模块] Web UI + 微信小程序
```

每个服务子模块都有各自的 `README.md`，包含架构、配置与 CLI 参考。

## 子模块配置

本仓库使用 Git 子模块管理各服务代码，并使用 Go 工作区（`go.work`）在本地联合构建。

### Git 子模块

| 子模块路径 | 远程仓库（SSH） | 说明 |
|------------|----------------|------|
| `nanoprotocol` | `git@gitee.com:kobeyoung81/nanoprotocol.git` | 共享协议库 |
| `nanobus` | `git@gitee.com:kobeyoung81/nanobus.git` | 消息总线服务 |
| `nanogateway` | `git@gitee.com:kobeyoung81/nanogateway.git` | 网关服务 |
| `nanosec` | `git@gitee.com:kobeyoung81/nanosec.git` | AI 代理服务 |
| `nanorunner` | `git@gitee.com:kobeyoung81/nanorunner.git` | 容器配置服务 |
| `nanoauth` | `git@gitee.com:kobeyoung81/nanoauth.git` | OAuth2/OIDC 认证服务 |
| `nanoportal` | `git@gitee.com:kobeyoung81/nanoportal.git` | Web 管理门户 |
| `nanoui` | `git@gitee.com:kobeyoung81/nanoui.git` | Web UI + 微信小程序 |

### Go 工作区

`go.work` 将 7 个 Go 模块联合构建，无需发布即可在本地相互引用：

```
go 1.26.2

use (
    ./nanoportal
    ./nanobus
    ./nanogateway
    ./nanoprotocol
    ./nanorunner
    ./nanosec
    ./nanoauth
)

replace github.com/xen0n/go-workwx/v2 v2.0.0-alpha.1 => ./nanogateway/go-workwx
```

构建所有服务：

```bash
go build ./nanobus/... ./nanogateway/... ./nanosec/... ./nanorunner/... ./nanoauth/... ./nanoportal/...
```

> 预提交钩子（通过 `./scripts/install-hooks.sh` 安装）会校验每个子模块也能以
> `GOWORK=off` 独立构建。

## 安装

### 前置依赖

- **Go 1.25+**（工作区基于 Go 1.26.2 构建；多数模块声明 `go 1.24`，总线声明 `go 1.25`）
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

> **无需配置 JWT 密钥。** `nanoauth` 在首次启动时自动生成 RSA 密钥对并存入总线背后
> 的配置（`service_config_items`，组件 `auth`，键 `jwtPrivateKey`/`jwtPublicKey`），
> 因此不需要生成或挂载任何密钥文件/机密。

### 2. 准备一个 MongoDB

平台只有**一个**存储：由 `nanobus` 持有的 MongoDB 库。其他服务都通过总线访问它，
因此总线的 URI 就是整个栈里唯一的数据库设置。Compose 会从 shell 环境变量或项目
`.env` 文件读取它：

```bash
cp .env.example .env    # 然后修改 NANOSEC_BUS_DATABASE_URI=...
```

也可以直接导出两个必需值：

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@db.example.com:27017/nanobus?authSource=admin"
export NANOSEC_BUS_INTERNAL_TOKEN="$(openssl rand -hex 24)"
```

> 这两个值在 `docker-compose.yml` 里都没有兜底（`:?`），缺少任何一个栈都会拒绝启动 ——
> 这正是提醒你去设置它们。

URI 必须写明总线独占的库名（上面是 `/nanobus`）。单机安装指向本机服务即可
（`127.0.0.1`，若 MongoDB 跑在 Docker 宿主机上则用 `host.docker.internal`）。

### 3. 启动整个栈

```bash
docker compose up -d
```

启动的服务：

| 服务 | 端口 | 用途 |
|------|------|------|
| `nanobus` | 9000 | 消息总线（WS + REST + SSE + 认证代理） |
| `nanoauth` | 8081 | OAuth2/OIDC 认证 |
| `nanorunner` | – | 容器配置（需要宿主机的 `docker.sock`） |
| `nanogateway` | 18080 → 8080 | 聊天平台适配器 + Web 聊天通道（门户同源代理） |
| `nanoportal` | 28080 → 80 | 管理 Web UI |

`bus-init` 会先运行：应用全部集合清单并写入内建目录，之后总线才启动。
`nanosec` 代理镜像不会随 `up` 启动 —— 它是 nanorunner 用来为每个用户配置代理容器的镜像。
需要时单独构建：

```bash
docker compose build nanosec
```

两个首次部署的注意点：

- **第一个管理员**：门户 <http://localhost:28080> 上**第一个注册的账号**自动成为管理员
  （配置项 `auth.firstUserIsAdmin`，默认开；公网可注册时请先关掉并手工指定）。
  规则只在「还没有任何管理员」时生效，且一次安装只触发一次。
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
docker compose exec nanobus nanobus config get gateway
docker compose exec nanobus nanobus config get agent
```

> 若未在总线配置中启用任何通道，`nanogateway` 会以 “no channels enabled” 退出。
> **Web 聊天通道默认启用**（`channels.web.enabled=true`，由 `nanoadmin config seed` 写入），
> 在 compose 网络内监听 `8080`、发布到宿主机 `18080`；门户也会同源代理它供聊天页使用。

### 5. 试运行

打开门户 **http://localhost:28080**（nanoportal 的发布端口），登录/注册后打开
**Chat** 创建代理并与之对话。或通过 CLI 通道聊天：

```bash
docker compose run --rm nanogateway --bus-url ws://nanobus:9000 --message "Hello"
```

### 不使用 Docker 的独立运行

自行启动 MongoDB 后，从工作区构建并运行各二进制。凡是访问存储的命令都读同一个
`NANOSEC_BUS_DATABASE_URI`：

```bash
export NANOSEC_BUS_DATABASE_URI="mongodb://nanosec:PASS@localhost:27017/nanobus?authSource=admin"

# 1. 应用集合清单（即 bus-init 与 admin-init 的步骤，按序执行）
go run ./nanobus/cmd/nanobus migrate up
go run ./nanoadmin/cmd/nanoadmin migrate up

# 2. 写入内建目录（admin-init 会跑全套）
go run ./nanoadmin/cmd/nanoadmin config seed
go run ./nanoadmin/cmd/nanoadmin permissions seed
go run ./nanoadmin/cmd/nanoadmin agent-types seed
go run ./nanoadmin/cmd/nanoadmin prompts seed
go run ./nanoadmin/cmd/nanoadmin skills seed
go run ./nanoadmin/cmd/nanoadmin mcp seed

# 3. 启动总线
go run ./nanobus/cmd/nanobus

# 4. 另开终端，为某个用户启动代理
go run ./nanosec/cmd/nanosec --user alice --bus-url ws://localhost:9000 --hypervisor-addr :9090

# 5. 启动网关（CLI 通道）
go run ./nanogateway/cmd/nanogateway --bus-url ws://localhost:9000
```

## 生产部署

完整运维指南见 [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)，包括：

- **Docker Compose**（单机）—— 即本文档
- **Docker Swarm** —— `deploy/swarm/docker-stack.yml`（`runner.backend=swarm`）
- **Kubernetes** —— `deploy/k8s/*`（`runner.backend=k8s`，RBAC 见 `nanorunner/deploy/k8s`）

## 环境变量配置前缀

| 服务 | 前缀 | 示例 |
|------|------|------|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_DATABASE_URI=mongodb://…` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL=...` |
| `nanosec` | `NANOSEC_` | `NANOSEC_OPENAI_API_KEY=...` |
| `nanorunner` | `NANOSEC_RUNNER_` | `NANOSEC_RUNNER_BUS_URL=...` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_BUS_URL=http://nanobus:9000` |
| `nanoportal` | `NANO_PORTAL_` | `NANO_PORTAL_BUS_URL=http://nanobus:9000` |
| `nanoui`（后端） | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR=:8088` |

> 网关、代理、Runner 的运行时配置主要来自总线配置项；上述环境变量覆盖连接层设置。
> `NANOSEC_BUS_` 是总线自己连 MongoDB 用的；其他服务都用 `NANOSEC_BUS_INTERNAL_TOKEN`
> 通过 HTTP 访问总线。

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
