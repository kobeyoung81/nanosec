# AGENT_HOME_DESIGN — Implementation Plan

**Version**: 1.0
**Date**: 2026-08-19
**Status**: Implemented (superseded in part — see the note below)

> **Update 2026-09-27:** the bootstrap-prompt work in Phase P4 (`agent.default.bootstrapPrompt`
> seed, admin-only write gate) was reverted: the key is deleted, `agent.bootstrapPrompt` is no
> longer projected, and `BuildSystemPrompt` no longer takes a base prompt. Prompts live in
> `agent_types.prompt` only. See `docs/BUNDLED_PROMPTS_DESIGN.md` §2.3.

Companion to `docs/AGENT_HOME_DESIGN.md`. Each phase lands in its own submodule commit +
super-repo bump; pre-commit hooks run standalone builds; Jenkins redeploys ≤5 min; per-agent
containers are recreated (dispose + reprovision) after nanosec/nanorunner image changes.

---

## Phase P1 — nanosec: per-agent paths + `agents/<id>` home layout

**Goal:** the agent process resolves and uses a per-agent home; shell cwd, tools, context
builder, cron, media, sessions all root under it.

- `internal/config/paths.go` — `ResolveAgentPaths(agentID string, p PathsConfig) (ResolvedPaths, error)`:
  derive defaults under `agents/<id>/agent/…` + `agents/<id>/workspace` + shared `sharedspace`,
  applying `p.*` overrides only when non-empty and not equal to the legacy seed defaults.
  Add `AgentRoot(agentID)` helper.
- `internal/config/config.go` — `AgentCoreConfig.BootstrapPrompt string`.
- `internal/config/defaults.go` — `DefaultBootstrapPrompt` constant + default.
- `internal/config/loader.go` — `applyAgentConfig` reads `m["agent.bootstrapPrompt"]`.
- `internal/agent/context.go` — add `bootstrapPrompt`; `BuildSystemPrompt` prepends it; remove
  `extraPrompt`/`SetExtraPrompt`.
- `cmd/nanosec/main.go` `runAgent` — compute `paths := config.ResolveAgentPaths(record.ID, merged.Paths)`;
  remove the `sessionDir/../agents/<id>/sessions` hack; `buildTools(agentHome, sharedspace)`;
  per-agent `cron.New(paths.CronFile, …)`, media tools, `AppendNoteTool`, ContextBuilder +
  `SetBootstrapPrompt`.
- `internal/workspace/manager.go` — `AgentWorkspace()` → `agents/<id>` (home root);
  `SharedWorkspace()` → `dataRoot/sharedspace`; `EnsureDirs`; `Resolve` containment (lexical now,
  symlink hardening in P2).
- `internal/hypervisor/server.go` — `handleListWorkspace` filters runtime entries (`sessions`,
  `cron.json`, `media`).
- `internal/agent/handler.go` — `AgentConfig.Workspace` → `agents/<id>`.

**Tests:** `paths_test.go` (derivation/override/legacy-as-unset), `context_test.go`,
`manager_test.go`, `hypervisor/server_test.go` (home browse + runtime-dir filtering).

**Verify:** `go build ./... && go test ./...`; recreate agent container.

---

## Phase P2 — nanosec: seeding + hardening

**Goal:** idempotent first-start home creation (placeholders + symlink), global/per-agent
skills, symlink-safe guards, sub-agents rooted at home, extended deny-patterns.

- `internal/agent/seed.go` (new) — `EnsureAgentHome(dataRoot, agentID)`: mkdir
  `agent/{bootstrap,memory,skills,sessions,media}` + `workspace/`; write placeholders
  `AGENT.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `MEMORY.md` if absent; create
  `agents/<id>/sharedspace -> ../../sharedspace` symlink if absent; ensure `<dataRoot>/sharedspace/`;
  copy global `/workspace/skills` when per-agent skills empty; migrate `dataRoot/shared` →
  `sharedspace` if present. Called at start of `runAgent`.
- `internal/skill/loader.go` — global + per-agent skills dirs; precedence per-agent → global →
  builtin.
- `internal/tool/filesystem.go` — `safePathIn` uses `EvalSymlinks` + canonical containment.
- `internal/workspace/manager.go` — `Resolve` uses `EvalSymlinks` containment.
- `internal/agent/subagent.go` — root at agent home.
- `internal/tool/shell.go` — extend `defaultDenyPatterns` (`find / -delete`, `shred`,
  `chmod -R 777 /`, `chown -R … /`, `mv / /`, `> /dev/sd`, `> /proc/sys`, `:(){`,
  `rm -rf ~/.nanosec`, …).
- Wire `tools.restrictToWorkspace`.

**Tests:** `seed_test.go`, `skill/loader_test.go`, `filesystem_test.go` (symlink escape
blocked), `manager_test.go` (symlink resolution).

---

## Phase P3 — nanorunner: disposable writable rootfs + hardening

**Goal:** agent can install tools (apk/pip work) but can't easily destroy the container or
escape; persistent data stays in home.

- `internal/runner/backend/docker/docker.go` — keep writable rootfs (no `ReadonlyRootfs`);
  `HostConfig.SecurityOpt`: `no-new-privileges:true` + `seccomp=<seccompProfile>` when
  configured (passed unconditionally; the **daemon** resolves the host path — in DinD or
  masked setups the daemon may not see the file, so keep `seccompProfile` empty to use
  Docker's default); extract `provisionConfig(...)` for testing.
- `seccomp/nanosec.json` (new, in nanorunner) — blocks `chroot`, `pivot_root`, `mount`,
  `umount2`, `open_by_handle_at`, `perf_event_open`, `bpf`, `init_module`/`finit_module`/
  `delete_module`, `kexec_load`, `swapon`/`swapoff`, `reboot`, `userfaultfd`,
  `process_vm_readv/writev`.
- config — add `seccompProfile` (default empty; daemon-host path when set); nanobus `runner`
  component seed item.
- nanosec `cmd/nanosec/main.go` — `os.Setenv("HOME", agentHome)`.

**Tests/verify:** unit `provisionConfig`; container-level (apk works, mount/reboot fail,
deny-patterns block destructive shell, `no-new-privileges` honored).

---

## Phase P4 — nanobus: bootstrap prompt + paths seeds + admin gate

**Goal:** seed `agent.default.bootstrapPrompt`; make `paths.*` derive; admin-only bootstrap
prompt.

- nanobus `cmd/nanobus/main.go` `defaultConfigItems` "agent" — add
  `ci("agent.default.bootstrapPrompt", <builtin text>, "string", …)`; set `paths.*` seeds to `""`.
- nanobus `migrations/030_agent_home_paths.sql` — clear `paths.*` values.
- nanoportal `server/internal/api/proxy.go` `handleSetConfig` — key `agent.default.bootstrapPrompt`
  requires `RoleAdmin`.
- tests: nanoportal server admin-gate test.

---

## Phase P5 — portal: browse home, wording, editing, system_prompt removal

- Browse root `agents/<id>` (automatic once P1/P2 land); confirm runtime-dir filtering.
- "Workspace" → "Home": `ChatWorkspacePanel.tsx`, `WorkspacePage.tsx`, `MyAccountPage.tsx`,
  `lib/navigation.ts`, `breadcrumbsForPath`.
- Remove "System prompt" field from `agent-form-dialog.tsx`; `api.ts` `AgentInput.system_prompt`
  optional.
- `ConfigsPage.tsx` — bootstrap prompt key read-only for non-admins.

**Verify:** `npm run build && npm run lint`.

---

## Phase P6 — migration & ops

- Recreate agent containers (dispose + reprovision) to apply nanosec/nanorunner images; confirm
  idempotent home seeding.
- Run nanobus migration (`nanobus migrate up`).
- Deploy step installs `seccomp/nanosec.json` to host `/etc/docker/seccomp/nanosec.json`.
- Update `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, `docs/AGENT_HOME_DESIGN.md` (status).
- End-to-end verification: AGENT.md editable from portal → next turn; bootstrap prompt
  admin-only; apk install works but container destroy is hard; sharedspace writable via
  `agents/<id>/sharedspace`.

---

## Notes

- Bootstrap prompt text is duplicated (nanosec constant + nanobus seed); nanosec constant is the
  fallback when the DB value is empty.
- `shared` → `sharedspace`: P2 migrates an existing `shared/`; new agents use `sharedspace`.
- Legacy `paths.*` seeds are treated as "unset" by the resolver so P1 works before the P4
  migration clears them.
