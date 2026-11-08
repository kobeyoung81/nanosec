# Management Portal Design Document

**Version**: 1.2  
**Date**: 2026-08-15  
**Status**: Current

---

## 1. Summary

This document designs the **management portal** for myriadmind as a combined **frontend + backend** product. The portal gives operators and administrators a single system for:

1. Viewing health and operating status of all major project components.
2. Inspecting essential component and user data needed for diagnosis and daily operations.
3. Managing global service configuration and per-user/per-agent overrides.
4. Auditing changes and understanding effective runtime configuration.

The design is grounded in the current architecture: `nanobus`, `nanogateway`, `nanosec`, `nanorunner`, MySQL-backed queues and registries, and bus-managed `service_configs`. Where the current platform does not yet expose enough observability or governance data, this document proposes the missing backend APIs and data models.

> **Current implementation status (2026-08-15):** The `nanoportal` submodule ships a React
> (Vite) admin UI behind a Go API (`/api/admin/v1/*`): overview dashboard, users + user
> details (bindings/agents/status/tier), agent records + sessions, service **Configs**
> editor, audit log (migration 018), alert rules (migration 019), workspace browser via
> the nanosec hypervisor, container dispose, and browser chat. Authorization uses an
> `Authorizer` with `RequireRole` / `RequireOwnership`; the portal reads everything
> over the bus (`NANO_PORTAL_BUS_URL` + the shared internal token) and reports a bus
> error rather than falling back to sample data.

---

## 2. Goals and Non-Goals

### 2.1 Goals

- Provide a single operational view across bus, gateway, agent fleet, runner, and core dependencies.
- Surface essential operational data without forcing operators into raw SQL, logs, or JSON.
- Support safe configuration changes for:
  - global service configs
  - channel-specific gateway config
  - per-user/per-agent overrides
- Make changes auditable, diffable, and reversible.
- Separate operator UI concerns from backend policy, validation, and secret handling.

### 2.2 Non-Goals

- End-user chat UI
- Replacing a full observability stack or log search platform
- End-user billing or subscription checkout
- Plaintext secret browsing
- Direct raw-table editing by portal users

---

## 3. Design Assumptions

### 3.1 Confirmed Assumptions

- The portal is an admin-facing management console.
- Admins can edit both global service configs and per-user/per-agent overrides.

### 3.2 Current Platform Foundations

| Existing foundation | How the portal uses it |
|---|---|
| `service_configs` | Global config source of truth for `bus`, `gateway`, `agent`, `runner` |
| `users` + `user_channels` | User list, tier, status, channel bindings |
| `inbound_queue` + `outbound_queue` | Queue depth, backlog, processing health |
| `container_requests` | Runner workload and lifecycle visibility |
| `wechatkf_sync_state` | WeChat KF sync and callback state visibility |
| `UpdateUserStatus` | Existing path for user status and tier changes |

### 3.3 Current Gaps

The current platform does **not** yet define enough backend support for a strong management portal. The portal design therefore adds:

- component heartbeat and metrics tables
- config publish history and audit tables
- per-user/per-agent override tables
- admin roles and sessions
- alert rules and delivery records
- a dedicated admin API/backend service

---

## 4. Recommended Solution Shape

### 4.1 High-Level Components

1. **Portal Frontend** — desktop-first web app for operators.
2. **Portal Backend** — dedicated admin API/BFF service.
3. **MySQL** — source of truth for portal read models and audit data.
4. **Existing Services** — `nanobus`, `nanogateway`, `nanosec`, `nanorunner`.

### 4.2 Recommended Backend Service

Add a dedicated backend service, referred to here as **portal backend**.

Its responsibilities:

- authenticate portal users
- enforce roles and field-level permissions
- aggregate operational data for the frontend
- validate config changes
- persist audit history
- compute effective configs
- coordinate status and tier changes with existing services

### 4.3 Why a Dedicated Backend

- avoids exposing MySQL directly to the browser
- centralizes policy and secret masking
- makes diffing, rollback, and approval logic enforceable
- reduces coupling between UI and internal schemas

---

## 5. Frontend Design

### 5.1 Personas

| Persona | Needs |
|---|---|
| Platform Admin | Global health, service config changes, rollout safety |
| Ops / SRE | Queue depth, degraded components, runner and dependency status |
| Support / Customer Ops | User status, tier, agent state, recent errors, safe override controls |
| Auditor | Read-only access to config history and operational actions |

### 5.2 Information Architecture

1. **Overview**
2. **Components**
3. **Users & Agents**
4. **Config Center**
5. **Events & Audit**
6. **Settings**

### 5.3 Overview Dashboard

### Summary Cards

| Card | Content |
|---|---|
| System Health | Healthy / degraded / major incident |
| Active Users | Count of active users and recent trend |
| Agent Fleet | Running agents, idle agents, unavailable agents |
| Queue Backlog | Pending inbound/outbound totals |
| Runner Capacity | Active containers, pending requests, tier pressure |
| Tier Distribution | Count of free/pro/ultra users |

### Health Map

Show tiles for:

- `nanobus`
- `nanogateway`
- `nanosec` fleet
- `nanorunner`
- MySQL
- LLM provider connectivity
- WeChat KF integration

Each tile shows:

- current status
- last heartbeat
- last error time
- key secondary metric

### 5.4 Components Workspace

The Components page lists service types first, then allows drill-in to service detail and instance detail.

| Component | Core status | Essential data |
|---|---|---|
| nanobus | WebSocket server health | connection count, inbound backlog, outbound backlog, config version |
| nanogateway | Channel health | enabled channels, callback state, outbound lag, ack status |
| nanosec fleet | Agent coverage | active agents, stalled users, processing latency, default model |
| nanorunner | Provisioning health | pending requests, active containers, quota saturation by tier |
| MySQL | Dependency health | connectivity, queue growth, slow-query indicator |

### 5.5 Users & Agents Workspace

### User List Columns

- user ID
- status
- tier
- channel bindings
- agent status
- last activity
- active override badge

### User Detail Tabs

1. **Profile**
2. **Channels**
3. **Agent**
4. **Containers**
5. **Overrides**
6. **Events**

### 5.6 Config Center

### Directory Login (LDAP)

Management section, `/admin/directory`. Configuring a directory was the hardest
thing in the console to get right, so this page is a typed editor over the same
`service_config_items` rows (component `auth`) the config center shows — both
surfaces edit one truth — plus the feedback a raw key list cannot give:

- a five-step connection probe (DNS, TCP, TLS, service bind, root DSE) that names
  the failure instead of guessing, and recognises Active Directory vs OpenLDAP;
- a lazily loaded directory tree with human labels (the `description` attribute
  when there is one) instead of bare DNs;
- an attribute sample that reports presence and uniqueness and suggests the
  filter and the identity attributes, warning when `mail` is ambiguous;
- a group picker for the sign-in allow-list;
- a login dry run: filter as rendered, entry matched, identity resolved, bind
  result, and what the real login would do (provision, link, refuse) — with
  nothing written anywhere.

The settings are saved key by key through the config API (audited as
`config.update`); the page's diagnostics are proxied to nanoauth
(`/auth/v1/directory/*`) with the caller's token, and nanoauth verifies it again,
so a direct call is held to the same rule.

### Global Config Areas

- `bus`
- `gateway`
- `agent`
- `runner`

### Global Config UX

- form mode for common fields
- raw JSON mode for advanced users
- schema validation before publish
- side-by-side diff
- secrets masked by default
- rollback to prior version

### Override UX

The portal should show both:

- base config
- override patch
- effective config after merge

### 5.7 Events & Audit

Show:

- config publishes
- user tier/status changes
- override changes
- alert state changes
- failed config validations
- admin login and high-risk actions

---

## 6. Backend Architecture

### 6.1 Backend Responsibilities

The portal backend is responsible for four categories of work:

| Category | Responsibility |
|---|---|
| Read APIs | dashboard, components, users, configs, audit views |
| Write APIs | config publish, override update, user status/tier changes, alert settings |
| Policy | auth, role checks, field-level restrictions, secret masking |
| Computation | effective config merge, health rollups, diff generation |

### 6.2 Integration Boundaries

### Reads

The backend reads directly from MySQL for:

- users
- queues
- container requests
- service configs
- proposed portal tables

### Writes

Recommended write behavior:

- use existing bus-compatible logic for user status/tier changes
- write config versions and audit records through portal backend validation flow
- write portal-specific tables directly

### Internal Dependency Model

| Backend dependency | Purpose |
|---|---|
| MySQL | source of truth for operational data and portal tables |
| nanobus protocol/client | user status updates, optional config coordination |
| future metrics ingest | heartbeat and snapshot writes from components |

### 6.3 Recommended Deployment

- Portal frontend served behind existing edge or reverse proxy.
- Portal backend deployed as a separate service.
- Backend connects to the same MySQL cluster as the core platform.
- Backend should be stateless and horizontally scalable.

---

## 7. Backend API Design

### 7.1 API Style

- REST for management operations
- JSON request/response bodies
- cursor or page-based pagination for lists
- optional SSE for live health updates

Base paths:

```text
/api/user/v1    — general-user surface (auth, me, own agents/sessions, self workspace + file upload/download)
/api/admin/v1   — admin surface (overview, components, users, configs, audit, alerts, runners, containers)
```

> The user-facing endpoints live under `/api/user/v1` so normal users never call
> "admin" endpoints; admin cross-user views reuse the owner-or-operator-gated
> agent/session/workspace endpoints with an operator token.

### 7.2 Authentication and Authorization

Recommended model:

- portal backend trusts upstream identity from SSO or auth proxy
- backend maps authenticated identity to internal admin roles

Minimum roles:

- `admin`
- `operator`
- `support`
- `auditor`

### 7.3 API Surface

### Health and Overview

| Method | Path | Purpose |
|---|---|---|
| GET | `/overview` | Summary cards, rollups, active alerts |
| GET | `/health-map` | Component tiles and top-level status map |
| GET | `/alerts` | Active and recent alerts |

### Components

| Method | Path | Purpose |
|---|---|---|
| GET | `/components` | List component groups and current health |
| GET | `/components/{componentType}` | Aggregate service-type view |
| GET | `/components/{componentType}/{instanceId}` | Instance detail |
| GET | `/components/{componentType}/{instanceId}/metrics` | Recent metrics snapshots |
| POST | `/components/{componentType}/{instanceId}/maintenance` | Enter or exit maintenance mode |

### Users and Agents

| Method | Path | Purpose |
|---|---|---|
| GET | `/users` | Paginated user list with filters |
| GET | `/users/{userId}` | User summary |
| GET | `/users/{userId}/channels` | Linked channels |
| GET | `/users/{userId}/agent` | Agent status and effective settings |
| GET | `/users/{userId}/containers` | Container requests and state |
| PATCH | `/users/{userId}/status` | Update user status |
| PATCH | `/users/{userId}/tier` | Update tier using validated admin flow |

### Config Center

| Method | Path | Purpose |
|---|---|---|
| GET | `/configs` | List config domains and versions |
| GET | `/configs/{componentType}` | Current global config |
| POST | `/configs/{componentType}/validate` | Validate candidate config |
| POST | `/configs/{componentType}/publish` | Publish config version |
| POST | `/configs/{componentType}/rollback` | Roll back to prior version |
| GET | `/configs/{componentType}/history` | Publish history |

### Directory Login (implemented surface)

| Method | Path | Purpose |
|---|---|---|
| GET | `/directory/effective` | Settings currently in force (never the bind password) |
| POST | `/directory/validate` | Field-level validation of a draft |
| POST | `/directory/test` | Five-step connection probe |
| POST | `/directory/browse` | One level of the directory tree |
| POST | `/directory/analyze` | Attribute sample with the settings it suggests |
| POST | `/directory/search` | Filtered search (the group picker) |
| POST | `/directory/check` | Login dry run: what would happen, writing nothing |

Settings themselves are not part of this surface: they are read and written
through `GET/PUT /configs/auth[/{key}]`.

### Overrides

| Method | Path | Purpose |
|---|---|---|
| GET | `/overrides` | List active overrides |
| GET | `/overrides/{subjectType}/{subjectId}` | Subject overrides and effective config |
| PUT | `/overrides/{subjectType}/{subjectId}` | Replace override set |
| PATCH | `/overrides/{subjectType}/{subjectId}` | Partial override update |
| DELETE | `/overrides/{subjectType}/{subjectId}` | Disable override |

### Audit and Events

| Method | Path | Purpose |
|---|---|---|
| GET | `/audit/events` | Portal and config audit stream |
| GET | `/audit/events/{eventId}` | Event detail |
| GET | `/audit/logins` | Admin login and auth events |

### Settings

| Method | Path | Purpose |
|---|---|---|
| GET | `/settings/roles` | Role definitions and assignments |
| PUT | `/settings/roles/{adminUserId}` | Update admin role assignment |
| GET | `/settings/alerts` | Alert rules |
| PUT | `/settings/alerts/{ruleId}` | Update alert rule |

### 7.4 Selected Response Shapes

### GET `/overview`

```json
{
  "system_health": "degraded",
  "summary": {
    "active_users": 128,
    "running_agents": 96,
    "pending_inbound": 24,
    "pending_outbound": 5,
    "active_containers": 37
  },
  "tier_distribution": {
    "free": 81,
    "pro": 39,
    "ultra": 8
  },
  "top_alerts": [
    {
      "rule_id": "gateway-wechatkf-lag",
      "severity": "warning",
      "message": "WeChat KF outbound lag above threshold"
    }
  ]
}
```

### GET `/users/{userId}/agent`

```json
{
  "user_id": "alice",
  "agent_status": "healthy",
  "last_activity_at": "2026-04-26T07:00:00Z",
  "effective_config": {
    "model": "gpt-4o",
    "max_iterations": 20,
    "web_tool_enabled": true
  },
  "overrides": [
    {
      "scope": "agent",
      "status": "active"
    }
  ]
}
```

### POST `/configs/agent/publish`

```json
{
  "comment": "Increase default shell timeout for Pro users",
  "draft_config": {
    "provider": {
      "default_model": "gpt-4o"
    }
  },
  "publish_strategy": "immediate"
}
```

### 7.5 Write Semantics

- All writes create audit events.
- Config writes require validation before publish.
- High-risk writes require elevated role.
- Secret fields are accepted on write but masked on read.
- User tier changes should update both admin audit history and runtime-facing state.

---

## 8. Data Model Design

### 8.1 Reused Existing Tables

The portal backend reuses:

- `users`
- `user_channels`
- `inbound_queue`
- `outbound_queue`
- `container_requests`
- `wechatkf_sync_state`
- `service_configs`

### 8.2 Proposed Portal Tables

### Admin Identity and Access

```sql
CREATE TABLE admin_users (
    admin_user_id    VARCHAR(255) PRIMARY KEY,
    display_name     VARCHAR(255) NOT NULL,
    email            VARCHAR(255),
    status           ENUM('active', 'disabled') DEFAULT 'active',
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE admin_role_bindings (
    admin_user_id    VARCHAR(255) NOT NULL,
    role             ENUM('admin', 'operator', 'support', 'auditor') NOT NULL,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (admin_user_id, role)
);
```

### Component Health and Metrics

```sql
CREATE TABLE component_heartbeats (
    instance_id      VARCHAR(255) PRIMARY KEY,
    component_type   VARCHAR(64) NOT NULL,     -- "bus", "gateway", "agent", "runner"
    component_name   VARCHAR(255) NOT NULL,
    status           ENUM('healthy', 'degraded', 'offline', 'misconfigured', 'maintenance') NOT NULL,
    version          VARCHAR(64),
    meta_json        JSON,
    last_seen_at     TIMESTAMP NOT NULL,
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE component_metrics_snapshots (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    instance_id      VARCHAR(255) NOT NULL,
    component_type   VARCHAR(64) NOT NULL,
    metrics_json     JSON NOT NULL,
    captured_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_component_time (component_type, captured_at),
    INDEX idx_instance_time (instance_id, captured_at)
);
```

### Config Versioning and Audit

```sql
CREATE TABLE config_revisions (
    revision_id      BIGINT AUTO_INCREMENT PRIMARY KEY,
    component_type   VARCHAR(64) NOT NULL,     -- "bus", "gateway", "agent", "runner"
    version          INT NOT NULL,
    config_json      JSON NOT NULL,
    published_by     VARCHAR(255) NOT NULL,
    publish_comment  TEXT,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_component_version (component_type, version)
);

CREATE TABLE config_change_audit (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    actor_id         VARCHAR(255) NOT NULL,
    target_type      VARCHAR(64) NOT NULL,     -- "global_config", "override", "user_tier"
    target_id        VARCHAR(255) NOT NULL,
    action           VARCHAR(64) NOT NULL,     -- "create", "update", "publish", "rollback", "delete"
    before_json      JSON,
    after_json       JSON,
    comment          TEXT,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Per-User / Per-Agent Overrides

```sql
CREATE TABLE agent_overrides (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    subject_type     ENUM('user', 'agent') NOT NULL,
    subject_id       VARCHAR(255) NOT NULL,
    scope            VARCHAR(64) NOT NULL,     -- "agent", "tools", "channel"
    config_patch     JSON NOT NULL,
    status           ENUM('active', 'disabled') DEFAULT 'active',
    created_by       VARCHAR(255) NOT NULL,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_subject_scope (subject_type, subject_id, scope)
);
```

### Alerting

```sql
CREATE TABLE alert_rules (
    rule_id          VARCHAR(128) PRIMARY KEY,
    component_type   VARCHAR(64) NOT NULL,
    metric_key       VARCHAR(128) NOT NULL,
    comparison       ENUM('gt', 'gte', 'lt', 'lte', 'eq') NOT NULL,
    threshold_value  DOUBLE NOT NULL,
    severity         ENUM('info', 'warning', 'critical') NOT NULL,
    enabled          TINYINT(1) DEFAULT 1,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE alert_events (
    event_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    rule_id          VARCHAR(128) NOT NULL,
    instance_id      VARCHAR(255),
    status           ENUM('open', 'acknowledged', 'resolved') NOT NULL,
    message          TEXT NOT NULL,
    opened_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at      TIMESTAMP NULL
);
```

### 8.3 Effective Config Model

The backend should compute effective config with this precedence:

1. global `service_configs`
2. portal-published global revision metadata
3. active per-user/per-agent override
4. runtime-only safety policy if needed

The UI should always display:

- base config
- override patch
- effective merged config

---

## 9. Core Backend Flows

### 9.1 Overview Read Flow

1. Backend reads latest component heartbeats.
2. Backend aggregates queue and container metrics from MySQL.
3. Backend computes overall system health.
4. Backend returns dashboard summary and top alerts.

### 9.2 Config Publish Flow

1. Admin submits candidate config.
2. Backend validates schema and policy.
3. Backend builds diff against current config.
4. Backend writes `config_revisions` and `config_change_audit`.
5. Backend updates `service_configs`.
6. Backend returns new version and effective publish status.

### 9.3 Override Update Flow

1. Operator edits user or agent override.
2. Backend checks editable-field policy.
3. Backend stores patch in `agent_overrides`.
4. Backend computes effective config for preview.
5. Backend records audit event.

### 9.4 User Tier / Status Change Flow

1. Admin submits change.
2. Backend checks role and reason.
3. Backend calls existing user-status update path.
4. Backend records audit event.
5. UI refreshes effective tier and impacted resource view.

---

## 10. Permissions and Safety

### 10.1 Roles

The platform has five roles. Their identifiers are historical: the *Operations*
role is stored as `support` and the *DevOps* role is stored as `operator`.

| Role (product) | DB value | Section access | Allowed actions |
|---|---|---|---|
| Admin | `admin` | all | all actions including role changes; may grant the `admin` role |
| Operations | `support` | Overview, Operations | manage non-admin users (role, tier, freeze, delete/restore, password reset), their containers, agents and storage |
| DevOps | `operator` | Overview, Management, Messages | platform config, models, capabilities, agent types, runners, alert rules |
| Audit | `auditor` | Overview, Audit | read operation logs, conversation logs, runtime status |
| Normal user | `user` | Workspace only | no admin-console access |

Section access is an explicit role set (not rank order), because Operations
(`support`, rank 60) owns Users while DevOps (`operator`, rank 80) owns the
platform catalog. See `nanoportal/server/internal/auth/authorizer.go`
(`SectionRoles`) and `nanoportal/web/src/lib/roles.ts` (`SECTION_ROLES`).

**Role assignment.** Only an `admin` may grant or revoke the `admin` role.
`Operations` may assign the non-admin roles, and may not modify or freeze
administrator accounts or act on their own account. The last active
administrator cannot be demoted, frozen or deleted.

### 10.2 Safety Rules

- secrets masked by default
- high-risk fields gated to `admin`
- every write requires actor identity
- every publish and rollback requires comment
- override scopes restricted to approved keys
- destructive actions require explicit confirmation

---

## 11. Operational Data Shown by the Portal

### nanobus

- active WebSocket connections
- pending inbound queue count
- pending outbound queue count
- oldest pending message age
- config version

### nanogateway

- enabled channels
- per-channel last inbound and outbound times
- ack enabled state
- WeChat KF cursor freshness
- callback token expiry

### nanosec Fleet

- active agents by user tier
- last processed message time by agent
- effective model by user
- average loop iterations
- session count and recent activity

### nanorunner

- pending container requests
- active containers by tier
- average provisioning time
- failed provisioning count
- Docker connectivity state

---

## 12. Delivery Phasing

### Phase 1

- portal frontend shell
- portal backend with auth and role model
- overview, components, users pages
- global config read/edit/publish
- audit history

### Phase 2

- per-user/per-agent overrides
- heartbeat-backed health model
- alert rules and alert events
- effective config previews

### Phase 3

- maintenance mode controls
- richer trend analytics
- staged rollout support
- bulk user operations

---

## 13. Final Recommendation

Build the management portal as a dedicated admin web application backed by a dedicated portal backend. The frontend should optimize for operational clarity, while the backend should own validation, role enforcement, config versioning, auditability, and effective-config computation. The most important product quality is trust: operators must be able to tell what is happening, what changed, who changed it, and what configuration is actually in effect.
