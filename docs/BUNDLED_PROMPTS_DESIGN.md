# Bundled Prompts Design: DB-Backed Agent Prompts, Code-Seeded

**Status**: Implemented
**Scope**: keep the built-in agent types' system prompts in the database (where
they are admin-editable), while shipping the platform baseline as a versioned
bundle in the nanobus binary and re-applying it on every deploy.

---

## 1. Problem

Each built-in agent type's system prompt is a column (`agent_types.prompt`) that
an administrator can edit on the Agent Types page. The baseline text, however,
was written by one-shot migrations (`059_plan_build_personas.sql`, and the
`build` prompt was a copy of the Go constant `config.DefaultBootstrapPrompt`).
That has three consequences:

- improving a prompt needs a **new migration file** for every wording tweak;
- a migration either clobbers an admin's edit or (guarded by
  `prompt IS NULL`) silently misses rows that already had text;
- there is no way to tell "the platform wrote this" from "an admin edited this",
  so neither can be updated or protected reliably.

## 2. Design

Prompts become a **versioned bundle embedded in the nanobus binary**, seeded into
`agent_types.prompt` by `nanobus prompts seed`, which the bus-init container runs
on **every deploy** (alongside `config seed` and `skills seed`):

```
nanobus binary                          database (agent_types)
  internal/promptbundle/prompts/*.md
  internal/promptbundle/bundle.json  →  nanobus prompts seed  →  agent_types.prompt
     (id → version)                       (+ _prompt_hash/_prompt_version
                                           in agent_types.settings)
```

The bundle is the **platform baseline**, not the source of truth: the database
row stays authoritative and admin-editable, and the seeder only overwrites a
prompt it recognises as an unmodified seed.

### 2.1 Edit detection

`agent_types.settings` carries two bookkeeping keys written by the seeder:

| key | meaning |
|---|---|
| `_prompt_version` | bundled version last written |
| `_prompt_hash` | `sha256(prompt text)` at that moment |

`promptbundle.ContentHash` is sha256-hex over the text, which deliberately
matches MySQL's `SHA2(text, 256)` — that lets `070_agent_prompt_seed_baseline.sql`
stamp the baseline for prompt text that predates the bundle using SQL alone.

### 2.2 Seeding rules (`store.SeedPlatformPrompts`)

| stored prompt | recorded baseline | action |
|---|---|---|
| empty | none | **fill** from the bundle |
| non-empty | none | **skip** (admin-owned; predates the baseline) |
| hashes to the baseline | present | **replace** with the bundled text, restamp |
| does not hash to the baseline | present | **skip** — an admin edited it (`--force` overrides) |
| equals the bundled text | present | no-op |
| type does not exist | — | **skip** (the bundle never creates types) |

Only `prompt` and the two `settings` keys are written. `role`, the execution
attributes (`strategy`/`context`/`output`/`session_binding`), permissions, models
and capability baselines are untouched — `SaveAgentType` already protects the
structural columns of seeded types.

### 2.3 Prompt composition (nanosec)

`ContextBuilder.BuildSystemPrompt` starts from the active definition's own prompt
(build, plan, a subagent profile) and appends the per-agent context after it:

    definition prompt → AGENT.md identity + runtime → SOUL/USER/TOOLS → memory
    → skills → session/channel notes

There is **no shared base prompt** (removed 2026-09-27). Each definition carries
the norms its own mode needs, which is why the bundle is the only place prompt
text ever lives. An earlier design prepended a platform bootstrap prompt held in
`service_config_items` as `agent.default.bootstrapPrompt`; it was never effective
in practice because the agent snapshot shadowed it with the primary type's prompt,
so the norms were injected twice in build mode and from the wrong mode in plan
mode (which received `build.md`). The config keys, the snapshot projection and the
loader read are gone; `agent_types.prompt` is authoritative.

## 3. Operations

```sh
nanobus prompts seed            # apply the bundle, keep local edits
nanobus prompts seed --force    # also overwrite edited prompts
nanobus migrate status          # migrations remain the schema mechanism
```

This is the only place prompt text is written from code. Prompt *wording* changes
therefore ship as an edit to the embedded `.md` files plus a `bundle.json`
version bump — no migration required. Migrations remain for anything that is
schema or DB state (see `070_agent_prompt_seed_baseline.sql` for the baseline
stamp and the `plan_write` permission, and `071_session_policy.sql` for the
session cap).

**Order matters on a fresh store**: the seeder never creates a type, so
`nanobus agent-types seed` has to run *before* `nanobus prompts seed` (as
`bus-init` and the standalone steps in `DEPLOYMENT.md` §6 do). With the order
reversed, a store seeded from empty comes up with every built-in prompt blank
and only the next boot fills them in.

### 3.1 Language policy

Every bundled prompt is written in English. The language a reply is written in is
**not** something the prompt guesses: it is a two-level setting.

- `agent.language.default` (config item, seeded to `zh`) is the platform default.
- `users.preferred_language` is the account's override (empty = inherit).
- `nanosec` resolves the two into one tag and appends a **per-turn language note**
  to the mode note, which is the last system message before the question. The
  note's body is English too; only the language name is substituted
  (`Chinese (中文)`, `English`, …). One template, one variable — a per-language
  copy of the note would drift from `_common.md`.

There is deliberately **no** "follow the latest message" mode and **no** message
classification: the language is a setting, not a guess. A deployment that wants
English replies sets the default to `en`; a user who wants a different language
sets their own.

The policy that *uses* the note lives in `prompts/_common.md` (the `## Language`
section): write everything the user reads — including thinking the interface
shows — in that language; English in files, tool output, memory or the prompt is
content, not an instruction to switch; keep identifiers verbatim; write delegated
tasks in the same language. The role prompts repeat the short form of the same
rule because a subagent never sees `_common.md`.

## 4. Constraints

- Each prompt must stay well under the 64 KiB `TEXT` class on
  `agent_types.prompt`; the bundle test asserts this.
- The Agent Types admin UI must round-trip unknown `settings` keys when it saves
  a type, or it will drop `_prompt_hash`/`_prompt_version` and turn the row into
  "admin-owned" (harmless, but the baseline is lost).
- The seeder does not touch per-agent (`agent_type_overrides`) state: overrides
  are unaffected by a prompt re-seed.
