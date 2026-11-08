# Bundled Skills Design: DB-First Catalog, Code-Seeded

**Status**: Implemented
**Scope**: move the agent's bundled skills out of the nanosec binary and
per-agent template into the platform catalog, seeded by nanobus and
materialized by the nanosec hypervisor.

---

## 1. Problem

Bundled skills used to ship in two disconnected places inside nanosec:

- `internal/skill/builtin/` (embedded via `go:embed`), and
- `template/skills/` (copied into every agent home by `EnsureAgentHome` and
  also read as a global directory).

They were always present regardless of the platform catalog, could not be
enabled/disabled per agent type, and were never versioned. The platform already
had a full skill catalog (`skills` table, `agent_type_capabilities` baselines,
per-user acks), so the bundled skills lived outside the management process.

## 2. Design

The bundled skills become **read-only platform definitions** seeded from the
nanobus binary into the database, then materialized from the catalog to disk by
the hypervisor. nanosec contains no skill content.

```
nanobus binary                    database (skills table)         nanosec container
─────────────────                 ───────────────────────         ─────────────────
internal/skillbundle/skills/  ──►  origin='bundled'           ──►  hypervisor
  (go:embed, bundle.json)          stable id skill:bundled-<n>      materialize to
        │                          version + content_hash           agents/<home>/agent/skills
        └── `nanobus skills seed`        │                                │
            (bus-init)                   └── per-type baseline            └── agent loader
                                             (agent_type_capabilities)        (read-only)
```

### 2.1 Ownership

| Concern | Owner |
|---|---|
| Canonical bundle content | `nanobus/internal/skillbundle/skills/` |
| DB seeding | `nanobus skills seed` (run by the `bus-init` container) |
| Catalog + read-only enforcement | nanobus store / REST |
| Catalog → disk materialization | nanosec hypervisor (`internal/skillstore`) |
| Consumption (`load_skill`, prompt summary) | nanosec agent (`internal/skill`) |
| Builtin tool definitions | unchanged (self-healed from the agent binary) |

### 2.2 Seeding

`nanobus skills seed` loads the embedded packages (`skillbundle.Load`), computes
a sha256 content hash, and upserts them via `store.SeedPlatformSkills`:

- stable id `skill:bundled-<name>` so per-type baselines and per-user acks
  survive updates;
- `scope='platform'`, `origin='bundled'`, `status='published'`;
- on first insert, the default `build` type baseline is enabled;
- a newer bundle `version` replaces content and bumps
  `version`/`published_version`/`content_hash`;
- an older version is ignored (a stale binary cannot downgrade);
- an existing non-bundled row with the same name is never hijacked.

Bundled rows are **read-only**: admin `PUT`/`DELETE` on
`/api/v1/capabilities/skills/{id}` return `409`. The only mutable state is the
per-type enable/lock baseline in `agent_type_capabilities`.

### 2.3 Runtime

The hypervisor (the per-user control plane, `nanosec hypervisor`) owns the agent
home and is the only writer of the skills directory:

- before spawning an agent it resolves the agent snapshot, applies the
  capability resolution rule, and materializes the enabled skills
  (`internal/skillstore.Materialize`);
- it re-materializes on a `config_changed` event whose keys include
  `capabilities` (skill/attachment/agent-type edits), so running agents pick up
  changes without a restart;
- materialization is atomic (temp dir + rename) and takes over a colliding
  unmanaged directory by backing it up under `.legacy/` first, so legacy
  template copies can never shadow catalog updates while user edits are
  preserved;
- the agent process only reads the directory through the skill loader; it has
  no bundle, embed, template copy, or sync logic.

### 2.4 Updates

Platform skills are migrated by code: edit
`nanobus/internal/skillbundle/skills/<name>/`, bump its version in
`bundle.json`, and redeploy. The next `nanobus skills seed` publishes the new
version; agents apply it on the next capability reload. There is no
version-history table or pinning for bundled skills (by design).

## 3. Data model

Migration `065_skill_bundled_origin.sql` widens `skills.origin`:

```sql
ALTER TABLE skills
  MODIFY origin ENUM('platform','bundled','human','agent') NOT NULL DEFAULT 'human';
```

## 4. Out of scope

Skill secrets, version history/pinning, ack gating for bundled skills, an admin
skill-editor studio, and moving builtin tool definitions to the bus.

## 5. Key files

- `nanobus/internal/skillbundle/` — embedded bundle, `Load`, `ContentHash`.
- `nanobus/internal/store/skillseed.go` — `SeedPlatformSkills`, `BundledSkillID`.
- `nanobus/cmd/nanobus/main.go` — `skills seed` command.
- `nanobus/internal/server/rest_capabilities.go` — read-only guard + hashing.
- `nanosec/internal/skillstore/` — atomic catalog→disk materialization.
- `nanosec/internal/capability/` — shared resolution rule.
- `nanosec/internal/hypervisor/supervisor.go` — `prepare` / `reprepare`.
- `nanosec/internal/skill/loader.go` — per-agent directory loader (no fallback).
