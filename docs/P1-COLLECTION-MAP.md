# P1 集合映射（现状 → 目标前缀）

本文件是 P1「数据面合并」的定稿映射：把新实例上的两个库（`nanosec` / `nanoartifacts`）合并为一个库 `nanosec`，集合按模块前缀命名。目标态见《NanoSec 架构设计（目标态）》§06。

约定（来自目标态文档）：

- 一个集合只有一个写者；跨模块读数据一律走 API。
- 命名 `<前缀>_<实体>`，实体不重复前缀词。
- 根集合用前缀本身（`artifacts`）。
- 基础设施集合用 `sys_`，不许放业务数据。

## bus（nanobus）

| 当前 | 目标 | 说明 |
|---|---|---|
| `users` | `auth_users` | 账号主体 |
| `oauth_providers` | `auth_oauth_providers` | OAuth 提供方 |
| `refresh_tokens` | `auth_refresh_tokens` | 刷新令牌 |
| `git_browser_shortcuts` | `auth_git_shortcuts` | 用户级 Git 快捷路径 |
| `user_secrets` | `auth_secrets` | 用户密钥 |
| `system_flags` | `sys_flags` | 引导标记（一次性） |
| `agent_types` | `admin_agent_types` | 智能体类型目录 |
| `agent_type_overrides` | `admin_agent_type_overrides` | 类型覆盖 |
| `permission_keys` | `admin_permission_keys` | 权限键目录 |
| `models` | `admin_models` | 模型目录 |
| `model_providers` | `admin_model_providers` | 模型提供方 |
| `service_config_items` | `admin_config` | 运行期配置 |
| `audit_log` | `admin_audit_log` | 审计 |
| `alert_rules` | `admin_alert_rules` | 告警规则 |
| `builtin_tools` | `admin_builtin_tools` | 内置工具状态 |
| `mcp_servers` | `admin_mcp_servers` | MCP 服务 |
| `skills` | `admin_skills` | Skill 元数据 |
| `user_skill_acks` | `admin_user_skill_acks` | 用户 Skill 确认 |
| `session_head_prompts` | `admin_prompts` | 会话头提示词（目标表名） |
| `agents` | `portal_agents` | 智能体实例（用户面实体） |
| `agent_sessions` | `portal_sessions` | 会话投影（权威源在 agent 卷） |
| `agent_groups` | `portal_agent_groups` | 智能体分组 |
| `binding_agent_preferences` | `portal_binding_preferences` | 绑定偏好 |
| `inbound_queue` | `bus_inbound_queue` | 入站队列 |
| `outbound_queue` | `bus_outbound_queue` | 出站队列 |
| `wechatkf_sync_state` | `bus_wechatkf_sync_state` | 客服渠道同步状态 |
| `container_requests` | `provisioner_container_requests` | 容器请求 |
| `runners` | `provisioner_runners` | runner 心跳 |
| `schema_migrations` | `sys_migrations` | 迁移记录，`_id = "bus:<name>"`，`service = "bus"` |
| `counters` | `sys_counters` | 自增序号 |

## artifacts（nanoartifacts）

| 当前 | 目标 | 说明 |
|---|---|---|
| `artifacts` | `artifacts` | 根集合，不加前缀 |
| `artifact_versions` | `artifacts_versions` | 版本 |
| `artifact_grants` | `artifacts_grants` | 作品授权 |
| `spaces` | `artifacts_spaces` | 空间 |
| `space_grants` | `artifacts_space_grants` | 空间授权 |
| `nodes` | `artifacts_nodes` | 知识树节点 |
| `uploads` | `artifacts_uploads` | 上传句柄（临时） |
| `fs.files` | `artifacts_fs.files` | GridFS 文件元数据 |
| `fs.chunks` | `artifacts_fs.chunks` | GridFS 分块 |
| `schema_migrations` | `sys_migrations` | 迁移记录，`_id = "artifacts:<name>"`，`service = "artifacts"` |

## 迁移记录合并

两个服务原本各有一份 `schema_migrations`，`_id` 是迁移文件名。合并进 `sys_migrations` 时：

- `_id` 改为 `<service>:<原文件名>`；
- 增加 `service` 字段（`bus` / `artifacts`）；
- 读取时按 `service` 过滤，写入时带上同样前缀。

这样两个服务的迁移集合共享一张表，但互不误判「已应用」。

## 不迁移的东西

- `local` / `config` / `admin` 库：副本集内部与系统库，不动。
- 会话的权威数据（agent 容器里的 JSONL）：不在 MongoDB。
- 老实例上的库：P1 只处理新栈的新实例。

## 与目标态文档的差异（本文件补全）

目标态文档 §06 只列了每个前缀的**代表集合**，下面这些集合今天真实存在、文档没点名，按域归位如下（目标态文档不因此修改）：

| 集合 | 目标 | 归属 | 归位理由 |
|---|---|---|---|
| `agents` | `portal_agents` | portal | 用户的智能体实例，属门户聚合面（目标态未列） |
| `agent_groups` | `portal_agent_groups` | portal | 门户侧的分组展示状态 |
| `binding_agent_preferences` | `portal_binding_preferences` | portal | 渠道绑定的偏好 |
| `agent_type_overrides` | `admin_agent_type_overrides` | admin | 目录的覆盖层 |
| `model_providers` | `admin_model_providers` | admin | 目录的一部分 |
| `builtin_tools` | `admin_builtin_tools` | admin | 能力目录的一部分 |
| `mcp_servers` | `admin_mcp_servers` | admin | 能力目录的一部分 |
| `skills` | `admin_skills` | admin | 能力目录的一部分 |
| `user_skill_acks` | `admin_user_skill_acks` | admin | 能力目录的用户确认 |
| `alert_rules` | `admin_alert_rules` | admin | 配置的一部分 |
| `wechatkf_sync_state` | `bus_wechatkf_sync_state` | bus | 渠道游标，写者是总线 |
| `system_flags` | `sys_flags` | sys | 一次性安装标记，不属于任何模块 |

约束不变：一个集合只有一个写者。`auth_` 前缀在 P1 仍由总线写入（nanoauth 直连是 P2 的事），P1 只改名字、不搬写者。
