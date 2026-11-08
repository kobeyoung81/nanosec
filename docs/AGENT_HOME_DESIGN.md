# Agent Home & Workspace Design (Multi-Agent)

**Version**: 1.0
**Date**: 2026-08-19
**Status**: Implemented

> **Update 2026-09-27 — the bootstrap prompt is gone.** The
> `agent.default.bootstrapPrompt` config item described below was removed along
> with the config-plane prompt projection: prompts live in `agent_types.prompt`
> and the system prompt starts from the active definition's prompt, with no shared
> base (§2.3 of `docs/BUNDLED_PROMPTS_DESIGN.md`). That config key is
> **admin-only in the Config Center** no longer — it no longer exists.

---

## 1. Summary

MyriadMind is evolving from "one container, one shared context" toward a genuine
**multi-agent** model. Today each user has a container in which multiple agent
processes run, but their identity, bootstrap, memory, and skills are read from a
**global, ephemeral** `/workspace` template, while the per-agent "tool workspace"
(`agents/<agentID>/workspace`) is empty and not seeded. Context files are lost on
container recreation, and the portal cannot manage them.

This document designs a **per-agent home** rooted in the persistent data volume so that:

1. Every agent owns a persistent, writable **home** (`agents/<agentID>`) containing its
   identity, bootstrap docs, memory, skills, working files, sessions, cron, and media.
2. `AGENT.md`, `SOUL.md`, `USER.md`, and `TOOLS.md` are **user/agent editable** (portal +
   agent tools), with **placeholder defaults** created at initialization.
3. The agent's base behavior comes from a **built-in bootstrap prompt** that only
   **admins** may override (stored in the database as `agent.default.bootstrapPrompt`).
4. The agent may run tools/bash/CLI but **can only write inside its own home** (plus the
   shared space), enforced at both the OS layer and the tool layer.
5. All path locations are **configurable and layerable** per agent.

Non-goals: changing the container model (we keep one container per user), and
adding a separate persistence backend (we keep the per-user Docker volume).

---

## 2. Current State

### 2.1 Context / identity files (image template at `/workspace`)

`nanosec` ships a template baked into the image (`nanosec/Dockerfile`:
`COPY workspace/ /workspace/`):

| File | Role | Loaded by |
|---|---|---|
| `AGENT.md` | Core identity (fallback default if missing) | `ContextBuilder.identity()` |
| `bootstrap/SOUL.md`, `USER.md`, `TOOLS.md` | Optional context, concatenated into the system prompt | `ContextBuilder.loadBootstrapFiles()` |
| `memory/MEMORY.md`, `memory/YYYY-MM-DD.md` | Long-term + daily notes (last `memoryRecentDays`, default 3) | `ContextBuilder.loadMemory()` |
| `skills/<skill>/SKILL.md` | Workspace skills; override `embed` builtins | `skill.Loader` |

The per-agent system prompt from the portal (`AgentRecord.SystemPrompt`) is prepended as
`extraPrompt` (`internal/agent/context.go`). `BuildSystemPrompt` runs **per turn**
(`internal/agent/loop.go`), so file edits take effect on the next message.

### 2.2 The two divergent "workspaces"

- **Context workspace (GLOBAL, EPHEMERAL):** `/workspace/*`. Shared by **all** agents in
  the container. `AppendNoteTool` writes notes here. It lives in the image layer — the
  persistent volume only mounts `/root/.nanosec` — so **memory/preferences are lost on
  container recreation**.
- **Tool/portal workspace (PER-AGENT, PERSISTENT, EMPTY):** `~/.nanosec/agents/<agentID>/workspace`
  plus `~/.nanosec/shared`. Used by shell/read/write/edit/list tools (`cmd/nanosec/main.go`)
  and the portal workspace browser (`internal/workspace.Manager`). It is never seeded from
  the template, so it is empty and the portal shows nothing to manage.
- **Sessions (persistent):** `~/.nanosec/agents/<agentID>/sessions/*.jsonl`.

### 2.3 Topology

One container per **user** (`nanosec-agent-<userID>`, volume `nanosec-data-<userID>` →
`/root/.nanosec`). The in-container hypervisor supervises one `nanosec agent` process per
agent (`internal/hypervisor/supervisor.go`). "Multi-agent" today = several processes in one
user container with per-agent tool workspaces but a shared, ephemeral context home.

### 2.4 Config capability (`service_config_items`, component `agent`)

Flat key-value config seeded in `nanobus/cmd/nanobus/main.go` (`defaultConfigItems`):
`provider.*`, `agent.*`, `tools.*`, `media.*`, `paths.*`. Layering (nanosec
`internal/config/loader.go`):

```
agent.default.<k>  <  agent.<k> (legacy)  <  agent.<agentID>.<k> (per-agent)
```

Only model, `maxIterations`, and `system_prompt` are per-agent today; **`paths.*` are
global** and can't be overridden per agent. The session dir is derived with a path hack
(`filepath.Join(paths.SessionDir, "..", "agents", id, "sessions")`).

### 2.5 Write confinement today

The agent runs as **root**; the `bash` tool sets `cmd.Dir` to the workspace
(`internal/tool/shell.go`) but a shell command can `cd` anywhere and write anywhere (only a
few deny-regexes exist). File tools root at the workspace via a **lexical** prefix check
(`safePathIn`) that does **not** resolve symlinks — a symlink inside the workspace can
escape. Sub-agents are rooted at the global `/workspace` (`internal/agent/subagent.go`).

---

## 3. Target Layout

```
~/.nanosec/                                   ← persistent volume (nanosec-data-<userID>)
├── sharedspace/                             ← real shared root (all agents in the container)
└── agents/<agentID>/                        ← AGENT HOME: shell cwd · portal browse root · writable root
    ├── agent/                               ← identity + context + runtime (organizational group)
    │   ├── AGENT.md                         ← placeholder at init, user/agent editable
    │   ├── bootstrap/{SOUL,USER,TOOLS}.md   ← placeholders at init, editable
    │   ├── memory/{MEMORY.md, YYYY-MM-DD.md}
    │   ├── skills/<skill>/                  ← per-agent skills (overlay image/builtin)
    │   ├── sessions/*.jsonl                 ← per-agent transcripts
    │   ├── cron.json                        ← per-agent
    │   └── media/                           ← per-agent
    ├── workspace/                           ← working files
    └── sharedspace -> ../../sharedspace     ← symlink, sits directly under agents/<id>
```

Decisions baked into this layout:

- **Home = `agents/<agentID>/`.** The shell cwd, the portal browse root, and the writable
  root are all the agent home. The `agent/` subfolder is a clean grouping for identity +
  context + runtime files; `workspace/` holds working files; `sharedspace` is a symlink that
  sits directly under the home.
- **Persistence:** everything lives on the data volume, so identity, memory, skills, and
  notes survive container recreation.
- **Runtime dirs** (`sessions/`, `cron.json`, `media/`) are filtered from portal listings.

---

## 4. Prompt Hierarchy

Assembled per turn by `ContextBuilder.BuildSystemPrompt(channel, chatID)` in this order:

1. **Bootstrap prompt** — a **built-in constant** in nanosec, overridable only by admins via
   the DB config item `agent.default.bootstrapPrompt`. This is the base "who you are / how
   you work / safety" block that bootstraps the agent. Precedence: built-in default
   < admin DB value.
2. **`AGENT.md`** — per-agent identity; placeholder at init; user/agent editable.
3. **`SOUL.md`, `USER.md`, `TOOLS.md`** — placeholders at init; editable.
4. **Memory** — `MEMORY.md` + recent daily notes.
5. **Skills** — always-on skills + skills summary.
6. **Session** — channel + chat id.

`AgentRecord.SystemPrompt` (`extraPrompt`) is **deprecated**: per-agent instructions live in
the editable `AGENT.md`; the `ContextBuilder.extraPrompt` path is removed.

---

## 5. Configuration

### 5.1 Effective per-agent paths

Derived from `dataRoot + agentID` by default, overridable via the existing config layering
(global `paths.*` base, per-agent `agent.<id>.paths.*` highest priority):

| Key (per-agent `agent.<id>.paths.*`) | Default |
|---|---|
| `identityFile` | `agents/<id>/agent/AGENT.md` |
| `bootstrapDir` | `agents/<id>/agent/bootstrap` |
| `memoryDir` | `agents/<id>/agent/memory` |
| `skillsDir` | `agents/<id>/agent/skills` |
| `sessionDir` | `agents/<id>/agent/sessions` |
| `cronFile` | `agents/<id>/agent/cron.json` |
| `mediaBaseDir` | `agents/<id>/agent/media` |
| `workspaceDir` | `agents/<id>/workspace` |

Changes:

- New per-agent path resolution helper in nanosec (`ResolveAgentPaths(dataRoot, agentID, items)`).
- `workspace.Manager` updated to root at the agent home (`agents/<id>`) with the shared
  space target allowed; `EvalSymlinks`-based canonical-path verification.
- The `filepath.Join(paths.SessionDir, "..", "agents", id, "sessions")` hack is removed.
- Cron and media become **per-agent** (each agent process gets its own `cronSvc` and media
  dir).

### 5.2 Bootstrap prompt

- New seeded item `agent.default.bootstrapPrompt` (component `agent`), value = the built-in
  text, type `string`.
- **Admin-only write**: the nanoportal server enforces `RoleAdmin` for PUTs to this key, and
  the portal renders it disabled for non-admins.

### 5.3 Seed default updates (nanobus)

- `paths.*` seeds are changed from literal `/workspace/*` to empty (meaning "derive from the
  agent home"); the Config Center shows the effective/derived values.

---

## 6. Initialization (Seeding)

Idempotent first-start step (in the agent process or a small `nanosec seed` subcommand):

1. Ensure `agents/<id>/agent/{bootstrap,memory,skills,sessions,media}` and
   `agents/<id>/workspace` exist.
2. Ensure the real `sharedspace/` root exists.
3. Write **placeholders** for `AGENT.md`, `bootstrap/SOUL.md`, `bootstrap/USER.md`,
   `bootstrap/TOOLS.md`, `memory/MEMORY.md` **if absent** (never overwrite).
4. Create the `agents/<id>/sharedspace -> ../../sharedspace` symlink **if absent**.
5. (Optional) seed the default skill set into `agent/skills/` if empty.

The image `/workspace` template is kept as the **seed source** and the **global skill
fallback**; `skill.Loader` gains a second (global) skills dir so per-agent skills overlay the
global ones, which overlay `embed` builtins.

---

## 7. Reload Semantics

| Source | Reload trigger | Mechanism |
|---|---|---|
| `AGENT.md`, `bootstrap/*.md`, `memory/*` | Next user turn | `BuildSystemPrompt` runs per turn; files read fresh — no restart |
| Bootstrap prompt, model, paths, other config items | Config change in DB | Existing bus `ConfigChanges` → supervisor reload/restart (`AgentHandler.reloadConfig`) |
| Skills | Next turn (registry lists dirs) | Per-turn reload |

---

## 8. Write Confinement (cwd control)

### 8.1 CWD control — feasible

The `bash` tool already sets `cmd.Dir` (`internal/tool/shell.go`); we set it to the **agent
home** (`agents/<id>`). File tools resolve relative paths against the home root. So at the
tool layer the agent's working directory is fully controlled.

### 8.2 Container layer (disposable writable rootfs + hardening)

The agent runs as **root**, so the tool layer alone cannot stop `cd / && echo x > /etc/…`.
We deliberately do **not** make the rootfs read-only: admins/users must still be able to
install tools and binaries (`apk add`, `pip install`, custom builds). Instead the container is
made **hard to destroy** through disposability + OS hardening:

- **Disposable rootfs:** the container is provisioned from an image by nanorunner. Any rootfs
  write (software installs, system files) is **ephemeral** — it resets on container
  recreation. If the agent corrupts the rootfs, the supervisor crash-restart loop marks the
  agent `failed` and an admin **reprovision** recreates it from a clean image. The persistent
  data volume (`/root/.nanosec` = home + sharedspace) is never touched by this.
- **`no-new-privileges: true`** (Docker `SecurityOpt`) — prevents setuid/setgid privilege
  escalation.
- **Custom seccomp profile** (`seccomp/nanosec.json`, referenced from a daemon-host path via
  runner config) on top of Docker's default profile — blocks `chroot`, `pivot_root`, `mount`,
  `umount2`, `open_by_handle_at`, `perf_event_open`, `bpf`, `init_module`/`finit_module`/
  `delete_module`, `kexec_load`, `swapon`/`swapoff`, `reboot`, `userfaultfd`,
  `process_vm_readv/writev`. No effect on `apk`/`pip`.
- **Default capability drops + default seccomp** (Docker defaults) — already deny
  `CAP_SYS_ADMIN`, `CAP_SYS_BOOT`, `CAP_SYS_MODULE`, etc., so `reboot`, `mount`, `swapon`,
  kernel-module loading, and `mknod` fail without extra config.
- **No host access:** agent containers mount only the data volume (no Docker socket, no host
  PID/net mounts, no privileged mode).
- **Per-tier resource quotas** (memory/CPU) cap fork bombs and memory exhaustion.
- **`HOME` env** overridden to the agent home so `~` and tool caches (md2pdf, officecli)
  resolve into the persistent home instead of the ephemeral rootfs.

Tradeoff (intentional): the agent *can* write junk to the rootfs (ephemeral), but cannot
permanently damage the platform, cannot reboot/mount/modify the kernel, cannot touch other
users' data, cannot escape the container, and cannot escalate privileges. "Can't easily
destroy the container" is achieved through disposability + OS defaults + deny-patterns rather
than a hard read-only rootfs.

> **Custom seccomp caveat:** the seccomp profile path is resolved by the **Docker daemon's**
> filesystem. In Docker-in-Docker or otherwise-masked setups the daemon may not see host
> paths, so keep `runner.seccompProfile` empty (Docker's default seccomp + default capability
> drops apply) unless you have verified the daemon can read the profile file.

### 8.3 Tool layer (defense in depth)

- File tools (`read/write/edit/list`) rooted at the agent home + sharedspace target.
- `safePathIn` / `workspace.Manager.Resolve` switch from a lexical prefix check to
  **`EvalSymlinks` + canonical-path containment**, so a symlink cannot escape the home and the
  `sharedspace` symlink resolves to the whitelisted shared root.
- `AppendNoteTool` → per-agent `agent/memory`.
- Sub-agents (`SubagentConfig.Workspace`) → per-agent home (not global `/workspace`).
- **Extended shell deny-patterns** (best-effort first line) — block `find / -delete`,
  `shred`, `chmod -R 777 /`, `chown -R … /`, `mv / /`, `> /dev/sd`, `> /proc/sys`, `:(){`,
  `rm -rf ~/.nanosec`, etc., alongside the existing `rm -rf`, `dd`, `mkfs`, shutdown rules.
- Wire the dormant `tools.restrictToWorkspace` config (kept as an additional tool-layer gate).

---

## 9. Shared Space (`sharedspace`)

- Canonical location: `<dataRoot>/sharedspace` (real dir, shared by all agents in the
  container).
- Exposed inside each agent home as the symlink `agents/<id>/sharedspace -> ../../sharedspace`
  (created at seed time).
- Tools and the portal allow the shared root as a second allowed root; the symlink itself is
  only usable because `EvalSymlinks` resolves it to the whitelisted target (the symlink is
  created at seed time, and the seccomp profile prevents remount/pivot tricks).

---

## 10. Portal Changes

- **Browse root** becomes `agents/<id>` (home). Top level shows `agent/`, `workspace/`,
  `sharedspace`; runtime dirs (`sessions/`, `cron.json`, `media/`) are filtered from
  listings.
- **"Workspace" → "Home" wording** (labels only; URLs unchanged):
  - `ChatWorkspacePanel` header/title → "Home"; panel toggle label → "Toggle home panel".
  - `WorkspacePage` title/subtitle → "Home".
  - `MyAccountPage` "Open workspace" tooltips → "Open home".
  - Admin `navigation.ts` "Workspaces" → "Agent Homes"; breadcrumbs → "Home".
- `AGENT.md` / `bootstrap` / `memory` become **editable** through the existing file
  viewer/editor (they are markdown/text files under the browse root).
- The agent form's **system prompt** field is removed (deprecated in favor of `AGENT.md`).
- The bootstrap prompt config key is **admin-only** in the Config Center.

---

## 11. Cross-Repo Change Summary

| Repo | Changes |
|---|---|
| **nanosec** | per-agent path resolution; `agents/<id>` layout (home root cwd); ContextBuilder bootstrapPrompt + files (drop `extraPrompt`); seeding/placeholders + sharedspace symlink; skill loader (global + per-agent); `EvalSymlinks` hardening; subagent home; per-agent cron/media/sessions; `workspace.Manager` root = home |
| **nanorunner** | disposable writable rootfs (no `ReadonlyRootfs`); `no-new-privileges:true` + custom seccomp profile (`seccomp/nanosec.json` via daemon-host path); keep default cap drops + quotas; runner `seccompProfile` config |
| **nanobus** | seed `agent.default.bootstrapPrompt`; `paths.*` seeds → derive; admin-only write gate for the bootstrap prompt key |
| **nanoportal** | browse `agents/<id>`; hide runtime dirs; "Home" wording; AGENT.md/bootstrap editing; remove system_prompt field; admin-only bootstrap prompt field |
| **myriadmind (super)** | docs; submodule bumps |

---

## 12. Migration

- Existing agents get their home seeded **idempotently** on next start (placeholders only if
  files are absent; sharedspace symlink created).
- `/workspace`-resident memory/notes written by old agents cannot be recovered after a
  container recreation (they live in the image layer); documented as a known loss.
- `record.system_prompt` values: optionally auto-append into the seeded `AGENT.md` once, then
  the field is ignored.

---

## 13. Phased Implementation Roadmap

- **P1 — nanosec paths/layout:** per-agent path resolution; `agent/` home layout; shell cwd
  = `agents/<id>`; ContextBuilder (bootstrap prompt + files, drop `extraPrompt`); per-agent
  cron/media/sessions; `workspace.Manager` home root.
- **P2 — nanosec seeding/hardening:** init/seeding (placeholders, sharedspace symlink); skill
  loader (global + per-agent); `EvalSymlinks` containment; subagent home fix; extended shell
  deny-patterns; `restrictToWorkspace`.
- **P3 — nanorunner confinement (disposable):** keep writable rootfs; `no-new-privileges` +
  custom seccomp profile; `HOME` override; runner `seccompProfile` config; deploy installs the
  profile on the host.
- **P4 — nanobus config:** seed `agent.default.bootstrapPrompt`; `paths.*` seed updates;
  admin-only write enforcement.
- **P5 — portal:** browse `agents/<id>`; hide runtime dirs; "Home" wording; AGENT.md/bootstrap
  editing; remove system_prompt; admin-only bootstrap prompt field.
- **P6 — migration/ops + docs:** idempotent seeding for existing agents; deployment notes;
  README updates.

---

## 14. Resolved Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Layout | Home = `agents/<id>` (shell cwd + browse root + writable root); `agent/` groups identity/context/runtime; `workspace/` for working files |
| 2 | Context file editability | AGENT.md / SOUL / USER / TOOLS user+agent editable, placeholder at init |
| 3 | Bootstrap prompt | Built-in constant, admin-only DB override `agent.default.bootstrapPrompt` |
| 4 | Paths | Configurable + layerable (`agent.<id>.paths.*` over global `paths.*`) |
| 5 | `sharedspace` | Real dir `<dataRoot>/sharedspace`, symlinked at `agents/<id>/sharedspace` |
| 6 | cron/media/sessions | Per-agent, under `agent/` |
| 7 | `record.system_prompt` | Deprecated in favor of editable `AGENT.md` |
| 8 | Container model | Keep per-user container |
| 9 | Write confinement | Disposable writable rootfs + `no-new-privileges` + custom seccomp + default cap drops + quotas + extended deny-patterns + `EvalSymlinks` tool hardening; `HOME` override |
| 10 | Portal wording | "Workspace" → "Home" (labels only; URLs unchanged) |
