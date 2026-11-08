# MyriadMind — 离线发布包（内网部署）

- 版本日期：**__DATE__**
- 源码提交：**__COMMIT__**

本包含 **7 个预构建容器镜像** + 运行编排 + 安装/校验脚本，用于在**离线/内网**机器上安装 MyriadMind。
无需源码、无需联网构建（镜像是预构建的 `:latest`）。

## 结构

```
myriadmind-release-__DATE__/
├── images/                 # docker save 导出的 7 个镜像
│   ├── nanobus.tar         kobeyoung81/nanobus:latest
│   ├── nanoauth.tar        kobeyoung81/nanoauth:latest
│   ├── nanorunner.tar      kobeyoung81/nanorunner:latest
│   ├── nanogateway.tar     kobeyoung81/nanogateway:latest
│   ├── nanoportal.tar      kobeyoung81/nanoportal:latest
│   ├── nanoasr.tar         kobeyoung81/nanoasr:latest
│   └── nanosec.tar         kobeyoung81/nanosec:latest   ← agent 镜像（~1.6G）
├── compose/
│   ├── docker-compose.yml
│   └── .env.example
├── install.sh              # 加载镜像 + (重)启栈
├── verify.sh               # 健康检查
├── MANIFEST.txt            # commit / 子模块 / 镜像 ID / 大小 / sha256
├── CHECKSUMS.sha256
└── README-RELEASE.md
```

## 依赖

- **Docker 20.10+**、**Docker Compose v2**
- **外置 MongoDB**（本包不包含）。要求：
  - 一个库 `nanobus`，以及能读写它的用户。
  - **URI 必须用宿主 LAN IP**（如 `<host-lan-ip>`），**不要用 `*.home`** —— compose 网络内 `*.home` 会解析到 `127.0.0.1`。
  ```js
  // mongosh
  use nanobus
  db.createUser({ user: "nanosec", pwd: "<strong-password>",
                  roles: [{ role: "readWrite", db: "nanobus" }] })
  ```
- 端口：`9000`(nanobus)、`8081`(nanoauth)、`18080`(nanogateway)、`28080`(nanoportal)
- `nanorunner` 需要宿主 `/var/run/docker.sock`（用它给每个用户开 agent 容器）

## 安装

```sh
tar -xzf myriadmind-release-__DATE__.tar.gz
cd myriadmind-release-__DATE__

# 1) 第一次：生成 compose/.env 并提示编辑（随后退出）
./install.sh

# 2) 编辑 compose/.env：
#    NANOSEC_BUS_INTERNAL_TOKEN = $(openssl rand -hex 24)
#    NANOSEC_BUS_DATABASE_URI   = mongodb://nanosec:<pw>@<host-lan-ip>:27017/nanobus?authSource=admin
vi compose/.env

# 3) 再次：加载镜像并启动
./install.sh

# 4) 健康检查
./verify.sh
```

`install.sh` 会：`docker load` 每个 `images/*.tar` → `compose down`（保留卷）→ `compose up -d --no-build`。
首次启动时 `bus-init` 先执行 `nanobus migrate up` + 各 seed；`nanoauth` 首次启动把 RS256 JWT 私钥生成并存进 `nanobus`（`service_config_items.auth.jwtPrivateKey`）。

## 升级

用新发布包替换旧包后，同样执行 `./install.sh`（内部已 `down` + `load` + `up`）。
**数据在外置 MongoDB，不受影响**；agent 数据在容器卷里，`down` 不带 `-v` 不会删除。

> 之所以必须 `down` 再 `up`：`bus-init` 是 `restart: "no"`，且 `nanobus` 以 `service_completed_successfully` 依赖它；单纯 `up -d` 不会重跑已退出的 `bus-init`。

## 验证

```sh
curl http://localhost:9000/healthz     # nanobus
curl http://localhost:18080/healthz    # nanogateway（web channel）
curl -I http://localhost:28080/        # portal
```

浏览器打开 **http://<host>:28080**（首次在 Portal → Configs 里配置模型 provider 等）。

## 运维要点

- **备份**：`mongodump` 整个 `nanobus` 库。**备份含 `service_config_items.auth.jwtPrivateKey`**——按密钥对待；删掉这些行会让所有已签发 token 失效。
- **内部 token**：`NANOSEC_BUS_INTERNAL_TOKEN` 必须全栈一致（含 runner 开的 agent 容器）；改了要重起整栈。
- **agent 数据**：每个 agent 的 workspace/session 在容器卷 `{dataRoot}/agents/{agentID}`，保留卷才能保住用户数据。

## 安全提示

`nanorunner` 挂了宿主 `docker.sock`，**等价于宿主 root 权限**；其它服务没有该挂载。发布包本身不含任何密钥，仍建议只在受控网络内分发。

## 常见坑

| 症状 | 原因 | 处理 |
|------|------|------|
| 容器报 `dial tcp 127.0.0.1:27017` | URI 用了 `*.home` | 改用宿主 LAN IP |
| 栈卡在 `bus-init` / 起不来 | Mongo 不可达或 URI 错 | `docker compose -p myriadmind logs --tail=50 bus-init` |
| `nanogateway` 退出 `no channels enabled` | 未启用任何 channel | `docker compose ... exec nanobus nanobus config set gateway channels.web.enabled true`（web 默认已开） |
| 升级后行为没变 | `bus-init` 是 `restart:"no"` | 用 `./install.sh` 升级（它先 `down` 再 `up`） |
