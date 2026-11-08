# 智能体分组（Agent Groups）设计

Status: 已实现（2026-10-24）
Touches: `nanoprotocol`、`nanobus`、`nanogateway`、`nanoportal`（Go + web）

## 1. 目标与边界

用户侧的「智能体」列表支持一层**分组**：每个账号自己维护，一个智能体至多属于一个组，没有归属的进固定的「未分组」。

包含：分组增删改、拖拽排序、把智能体拖进组（或菜单「移动到分组」）、折叠/展开、新建/编辑智能体时选组。

不包含：嵌套分组、全局共享分组、一个智能体属于多个组、组内手动排序、管理端分组界面。折叠状态只存在浏览器里，不跨设备同步。

## 2. 数据模型

新集合 `agent_groups`（迁移 `nanobus/migrations-mongo/014_agent_groups.json`）：

| 字段 | 说明 |
|---|---|
| `_id` | uuid |
| `user_id` | 组的所有者；分组是用户私有的 |
| `name` | trim 后 1–40 rune，同一用户内唯一（唯一索引 `user_name`） |
| `position` | 显示顺序，`reorder` 重写 |
| `created_at` | |

索引：`(user_id, position)` 供列表读，`(user_id, name)` 唯一。

归属存在 `agents.group_id`（可空；没有该字段就是未分组）。没有单独的 assignments 集合：一个 agent 至多一个组，把归属放在 agent 文档上让列表与分组同源。

**删除分组**先对组内 agent `$unset group_id`，再删组文档；agent 本身不动。顺序是刻意的：先解绑后删组，最坏情况是留下一个空组（可以再删），而不是留下指向不存在组的 agent。

## 3. 协议与接口

`nanoprotocol` v0.42.0 在三个结构上各加一个字段（只加字段，不改既有语义）：

- `AgentInfo.GroupID string`（`omitempty`）——列表/详情带出归属；
- `CreateAgentRequest.GroupID string`——创建时直接入组；
- `UpdateAgentRequest.GroupID *string`——`nil` 不改，`""` 移出所有组。

分组本身的 CRUD 不进协议库，走 bus 的 REST（分组是门户的组织方式，不是运行时协议）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/agent-groups?user_id=` | `{groups:[{id,name,position}],count}`；空列表是 `[]` |
| POST | `/api/v1/agent-groups` | `{user_id,name}` → 201；重名 409；超 100 组 409；空名 400 |
| PUT | `/api/v1/agent-groups/{id}` | `{user_id,name}`；不存在/别人的组 404 |
| DELETE | `/api/v1/agent-groups/{id}?user_id=` | `{id,status,unassigned}` |
| POST | `/api/v1/agent-groups/reorder` | `{user_id,ids}`；ids 必须恰好列全该用户的组 |

portal 对用户暴露 `/api/user/v1/agent-groups*` 五个同形端点，**`user_id` 一律取自 JWT**，请求里带的会被覆盖。管理端不代理分组。

创建/更新 agent 时 `group_id` 必须属于该 agent 的所有者，否则 400 `unknown group`；WS 路径（`TypeCreateAgent`/`TypeUpdateAgent`）与 REST 规则一致。

## 4. 前端

**分桶规则**（`web/src/lib/agentGrouping.ts`，纯函数）：

1. 组按 `position` 升序；
2. 组内保持 agent 列表原顺序（即 `created_at`）；
3. `group_id` 为空或指向不存在的组 → 未分组（固定最后）；
4. 空组保留（可以先建组再拖）；
5. 未分组为空时不渲染该桶。

**拖拽**复用门户既有的指针实现（`workbench/Workbench.tsx` 的 `beginPanelDrag`），不依赖任何拖拽库：

- `web/src/hooks/usePointerDrag.ts`：把手 `pointerdown` 时 `setPointerCapture`，在 `window` 上跟 `pointermove`/`pointerup`/`pointercancel`，`Escape` 取消；`pointerup` 时提交解析结果。
- `web/src/lib/agentDrag.ts`：`groupPlacement`（指针在组头上下半区 → before/after）与 `moveGroupOrder`（移动并重编号，no-op 返回 null）。
- 目标解析：`document.elementFromPoint(...).closest('[data-agent-group-section]')` 得到目标组；命中 `[data-agent-group-header]` 时按上下半区决定插入位置。未分组 section 的 id 是空串，所以「拖进未分组」与「不在任何 section 上」能区分。
- 触摸设备（`hover: none`）禁用拖拽，只保留菜单「移动到分组」。

**持久化**

- 折叠状态：`clientState` 的新区域 `agentGroups.collapsed`（按账号命名空间）。
- 首屏快照：`listCache` schema 升到 3，把 `groups` 与 `agents` 一起缓存；schema 2 的快照直接作废重拉，避免「先全部画成未分组再跳位」。

## 5. 交互细节

- 选中一个位于折叠组的智能体时自动展开该组。
- 组头显示组内 agent 的聚合提醒点（运行中/等你回答），折叠时也不丢提醒。
- 删除组要二次确认，文案说明「组内 N 个智能体会变成未分组，智能体本身不会被删除」。
- 新建/编辑对话框有「分组」下拉；从组菜单「在此分组中新建智能体」会预选该组。

## 6. 测试

- bus store：CRUD、重名（唯一索引）、超限、删除解绑计数、reorder 合法性、用户隔离、`SetAgentGroup` 清空、创建带组且投影可读。
- bus server：五个端点的状态码、空数组、跨用户组 400、更新时 `nil`/`""` 三态、WS 路径同规则。
- gateway：`AgentInfo.GroupID` 原样透传。
- portal：代理路径、身份覆盖（请求里的 `user_id` 无效）、409/404 透传。
- web：`bucketAgents`、`moveGroupOrder`、分组 API 的路径/编码、缓存 schema、表单提交 `group_id`、列表已改为按组渲染（源码断言）。

## 7. 2026-10-25 打磨：组内顺序、未读、落点

### 7.1 组内顺序（服务端持久化）

- `agents.position`（int64）决定组内顺序：`arrange` 写 `0..n`；新建/重建的 agent 写 `time.Now().UnixMilli()`，所以自然排到组尾；没有该字段的历史文档按 `created_at` 兜底。
- 读：`GET /api/v1/agent-groups` 返回 `{groups:[{id,name,position,agents:[ids]}], ungrouped:[ids]}`，`ListAgentOrder` 一次查完再在内存分组（几十条量级）。
- 写：`POST /api/v1/agent-groups/arrange` `{user_id, groups:[{id,agents:[ids]}], ungrouped:[ids]}`。所有 id 必须属于该用户、组必须属于该用户、同一 agent 不能出现两次，否则 400 且不写入。一次请求覆盖跨组拖拽。
- **不动 nanoprotocol**：顺序属于门户的组织方式，不进入 agent 的线协议。

### 7.2 未读

- 数据源：attention 接口每行带 `updated_at`（最新段的服务器时间，RFC3339Nano）。
- 判定：浏览器把「读到时该会话的 `updated_at`」存进 `clientState` 的 `agentRead`；`updated_at > readAt` 即未读。两边都是服务器时间，**不比较本地时钟**。
- 基线：第一次拿到快照时，没有 readAt 的会话按当前 `updated_at` 视为已读，避免整屏历史变绿。
- 活动会话：正在屏幕上时，`applyLiveAttention` 直接把它标为已读（`unread=false`），并随快照把 readAt 推到最新。
- 多标签：readAt 用 `writeStateMerged` 合并，取较晚的服务器时间，慢标签不会把已读推回去。

### 7.3 圆点

- 蓝 `bg-info` = 有待定问题；黄 `bg-warning` = 运行中；绿 `bg-success` = 运行完成但未读。
- 黄绿互斥：`running` 时不渲染绿点。
- 三点都是 `size-1.5`、无动画（原来的运行点带 `animate-pulse`，看起来比别的大）。

### 7.4 拖拽落点

- 组拖拽：按**目标组整体**的上下半区在组的边缘画 2px 主色插入线。
- agent 拖拽：按目标行的上下半区在行边缘画插入线；落在组内空白处则追加到组尾。
- 整组 `ring` 高亮已移除，避免「覆盖/落进这个组」的误解；agent 拖拽时目标组只留很淡的背景。
