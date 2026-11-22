<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/lockup-dark.svg?v=2">
    <img src="docs/assets/lockup.svg?v=2" width="360" alt="NanoSec">
  </picture>
</p>

<p align="center">
  <strong>自托管、多用户的 AI 助手平台（Go 编写）</strong><br>
  每人一个容器，所有渠道，一个 MongoDB。
</p>

<p align="center">
  给那些要在自己的基础设施上运行 AI 工作区的团队与企业。
</p>

<p align="center">
  <a href="./README.md">English</a> · 简体中文
</p>

<p align="center">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-155DFC.svg" alt="License: AGPL-3.0"></a>
  <a href="https://go.dev"><img src="https://img.shields.io/badge/go-1.26-00ADD8.svg" alt="Go 1.26"></a>
  <a href="https://gitee.com/kobeyoung81/nanosec/releases"><img src="https://img.shields.io/badge/release-v0.1.0-155DFC.svg" alt="Release v0.1.0"></a>
</p>

<p align="center">
  <img src="docs/assets/console-light-zh.png?v=2" width="100%" alt="NanoSec 工作台：左侧智能体、下方对话列表、中间是会话与输入框">
</p>

<p align="center"><sub>工作台：左侧智能体、下方对话列表、中间是会话与输入框。浅色主题，1440 × 900。</sub></p>

<details>
<summary>深色主题</summary>

<p align="center">
  <img src="docs/assets/console-dark-zh.png?v=2" width="100%" alt="同一个工作台的深色主题">
</p>

</details>

## 你能得到什么

- 💬 **一个助手，所有渠道。** 网页对话、企业微信、飞书、微信客服、CLI 与微信小程序，
  都通向同一个人、同一段历史。
- 👤 **每人一个容器。** 每个账号都有自己的智能体容器，自己的文件系统、配额与工具体，
  由平台在 Docker、Swarm 或 Kubernetes 上拉起。
- 🛠 **它真的会干活，不只是聊天。** shell、文件读写、git 面板、网页抓取与搜索、
  定时任务、后台子智能体。
- 🧩 **一个人可以有几个智能体。** 每个角色有自己的提示词、模型与工具体；
  消息可以路由到合适的那个，也能在控制台里随时切换。
- 🧠 **会话不会丢。** 对话正文是容器里的 JSONL 文件，那是权威源；
  服务端只保留一份可重建的投影给界面用。
- 📚 **技能与提示词随平台发布。** 打包、带版本、开机灌进目录，
  不需要每次安装后手工调。
- 🗄 **一个 MongoDB，一个模块一组前缀。** `auth_ · admin_ · portal_ · bus_ ·
  provisioner_ · sys_ · artifacts_` —— 每个模块只写自己的前缀，跨模块读取走内部 HTTP。
- 🔒 **默认自托管。** 不需要消息队列、不需要对象存储、不绑任何 SaaS ——
  唯一的外部依赖是你自己选的那个模型 API。

## 快速开始

需要 Docker（Compose v2）和一个你能连上的 MongoDB 7+（单节点副本集就够）。
这套 compose **不带**数据库容器。

```bash
git clone --recurse-submodules git@gitee.com:kobeyoung81/nanosec.git
cd nanosec && cp .env.example .env
# 编辑 .env：NANOSEC_BUS_DATABASE_URI、NANOSEC_BUS_INTERNAL_TOKEN、NANOARTIFACTS_SESSION_SECRET
docker compose up -d
```

然后打开 **http://localhost:14403** 注册。全新安装的第一个账号就是管理员，
会自动得到一个默认智能体和一个容器请求 —— 容器起来后「对话」页立刻可用。

服务起来之前会先跑两个初始化容器：`admin-init` 应用清单并灌入目录数据，
`bus-init` 应用总线清单。智能体镜像不由 `up` 启动（它由供给服务按用户拉起），
但你可以先构建它：`docker compose build nanosec`。

宿主机端口：`14403` 控制台 —— 唯一对外发布的一个 —— 以及 `14400` 总线、`14401` 身份、
`14402` 网关、`14404` 管理，后四个只绑 `127.0.0.1`，给运维与探针用。

## 工作原理

<p align="center">
  <img src="docs/assets/architecture.svg?v=2" width="100%" alt="渠道进入同一个入口；八个服务共用一个数据库，每个模块一组前缀">
</p>

三条规则维持这个拆分：

1. **总线只运消息。** 入站与出站队列、事件流、通往智能体容器的隧道。
   别的东西不该放在那里。
2. **一个模块一组前缀。** 每个集合只属于一个服务；其他人要用，走那个服务的 API。
3. **服务之间走内部 HTTP**，带共享令牌 —— 不共享内存状态，也没有第二个数据库。

## 控制台

<p align="center">
  <img src="docs/assets/admin.png?v=2" width="100%" alt="管理端：平台健康、用户、容器与告警在同一个界面">
</p>

<p align="center"><sub>管理端：健康、用户、容器、审计与告警规则 —— 同一个外壳里的运维那一半。</sub></p>

<p align="center">
  <img src="docs/assets/artifacts.png?v=2" width="100%" alt="作品库：空间、目录与就地渲染的文档">
</p>

<p align="center"><sub>作品库：左边空间与目录，右边就地渲染发布出来的文档。</sub></p>

## 文档

| 文档 | 讲什么 |
|---|---|
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | 系统今天是怎么搭的：服务、数据归属、关键流程、安全边界 |
| [`docs/DEPLOYMENT.md`](./docs/DEPLOYMENT.md) | Compose、Swarm、Kubernetes；端口、环境变量、运维 |
| [`docs/PRD.md`](./docs/PRD.md) | 产品要做什么，以及刻意不做什么 |
| [`docs/README.md`](./docs/README.md) | `docs/` 下全部文档的索引 |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | 开发环境、分支、提交、PR 检查项 |

每个服务子模块都有自己的 `README.md`，写它的架构、配置键与命令行。

<details>
<summary>环境变量前缀</summary>

环境变量只承载连接级设置；运维参数放在 `admin_config` 里，在控制台编辑
（或用 `nanoadmin config set`）。

| 服务 | 前缀 | 例子 |
|---|---|---|
| `nanobus` | `NANOSEC_BUS_` | `NANOSEC_BUS_DATABASE_URI`、`NANOSEC_BUS_INTERNAL_TOKEN`、`NANOSEC_BUS_ADMIN_BASE_URL`、`NANOSEC_BUS_PORTAL_BASE_URL`、`NANOSEC_BUS_PROVISIONER_BASE_URL` |
| `nanogateway` | `NANOSEC_GATEWAY_` | `NANOSEC_GATEWAY_BUS_URL`、`NANOSEC_ADMIN_URL`、`NANOSEC_PORTAL_URL` |
| `nanoagent` | `NANOSEC_` / `NANOSEC_AGENT_` | `NANOSEC_AGENT_BUS_URL`、`NANOSEC_ADMIN_URL`、`NANOSEC_PORTAL_URL` |
| `nanoprovisioner` | `NANOSEC_RUNNER_` / `NANOSEC_PROVISIONER_` | `NANOSEC_RUNNER_BUS_URL`、`NANOSEC_RUNNER_BACKEND`、`NANOSEC_PROVISIONER_MONGO_URI`、`NANOSEC_PROVISIONER_ADDR` |
| `nanoadmin` | `NANOSEC_ADMIN_` | `NANOSEC_ADMIN_MONGO_URI`、`NANOSEC_ADMIN_ADDR`、`NANOSEC_BUS_URL` |
| `nanoauth` | `NANOAUTH_` | `NANOAUTH_MONGO_URI`、`NANOAUTH_ADDR`、`NANOAUTH_JWT_KEY_ID`、`NANOAUTH_WECHAT_APP_ID` |
| `nanoportal` | `NANO_PORTAL_` / `NANOPORTAL_` | `NANO_PORTAL_BUS_URL`、`NANOPORTAL_MONGO_URI`、`NANOSEC_ADMIN_URL` |
| `nanoartifacts` | `NANOARTIFACTS_` | `NANOARTIFACTS_MONGO_URI`、`NANOARTIFACTS_SESSION_SECRET`、`NANOARTIFACTS_QUOTA_BYTES`、`NANOSEC_PORTAL_URL`（智能体归属）、`NANOAUTH_INTERNAL_URL`（账号查询） |
| `nanoui`（后端） | `NANOUI_BACKEND_` | `NANOUI_BACKEND_ADDR` |

`NANOSEC_BUS_INTERNAL_TOKEN` 是全平台共享密钥：所有内部面（`/internal/v1/*`）只接受
带它的请求；没有配置时直接拒绝。`NANOSEC_ADMIN_URL` 是服务找自己配置的地方。

</details>

## 状态与路线

- **已发布：** [`v0.1.0`](https://gitee.com/kobeyoung81/nanosec/releases) —— 整个平台，
  十个镜像的版本由 `versions.lock` 一起确定。
- **可用：** 全部渠道的消息收发、一人多智能体、工具与技能、在 Docker / Swarm /
  Kubernetes 上的容器供给、管理端、作品库。
- **进行中：** 服务拆分收尾 —— 总线上的最后几处兼容转发、集群前提（副本集、共享卷），
  以及文档跟上代码。
- **计划中：** 见 [`docs/PRD.md`](./docs/PRD.md)。

## 参与贡献

1. 先读 [`CONTRIBUTING.md`](./CONTRIBUTING.md)，装上钩子：`./scripts/install-hooks.sh`。
2. 从 `master` 开分支，命名 `feat/xxx` 或 `fix/xxx`。
3. 改过的模块都要构建与测试 —— 超仓根目录没有 `go.mod`，
   命令要在模块目录里跑：`cd nanoauth && go build ./... && go vet ./... && go test ./...`。
4. 提 PR 时写清改了什么、怎么验证的、是否动到 `nanoprotocol` 或某个集合的形状。

改 `nanoprotocol` 的顺序是固定的：先提交协议改动，跑
`./scripts/bump-protocol.sh vX.Y.Z`，在每个使用方提交 `go.mod`/`go.sum`，
最后先推子模块、再推超仓。

## 安全

发现问题请不要开公开 issue。按 [`SECURITY.md`](./SECURITY.md) 里的方式私下报告，
我们三个工作日内回复。

## 许可证

[AGPL-3.0](./LICENSE)。名称与标志另有说明 —— 见 [`NOTICE`](./NOTICE)。
