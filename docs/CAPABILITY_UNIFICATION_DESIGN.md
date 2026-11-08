# Capability Unification Design: Models, Skills, MCP & Built-in Tools

**Version**: 1.0
**Date**: 2026-09-14
**Status**: Locked
**Supersedes**: Consolidated Spec Rev 3 (Models, Skills, MCP & Built-in Tools)

---

## 0. Purpose & Scope

This document defines one unified organizational model for the four capability
types — **Models**, **Skills**, **MCP services**, and **Built-in Tools** — plus
the first-class **AgentType** that sits between the platform and an agent.

It supersedes the Consolidated Spec Rev 3. Where that spec relied on
"copy-then-fork" and left "Agent type" undefined, this design makes the
ontology explicit and derives every behavior from a small set of axioms, so
individual decisions no longer need to be made case by case.

**In scope:** capability definitions, AgentTypes, per-agent selection,
permissions, skill lifecycle, credentials, naming.

**Out of scope:** native Anthropic/Google clients (OpenAI-compatible only for
now), credential encryption at rest, admin browsing user-created items, users
editing platform-owned definitions.

---

## 0.1 Decision Log (canonical)

| # | Decision | Choice |
|---|---|---|
| 1 | Ontology | Definitions plane \| platform-owned **AgentType** \| user-owned **Agent** |
| 2 | Propagation | Live resolution; `lock > instance > type default`; lock/pin is the only freeze |
| 3 | AgentType | First-class entity; role types are platform-owned singletons; `plan`/`build` are **modes**, not types |
| 4 | Role models | Per-agent `title_model`/`summarize_model`/`subagent_model` fold into role-type defaults, then the columns are dropped |
| 5 | Permissions | `allow` / `ask` / `deny`, wildcard-matched, last-match-wins; enablement is a separate axis |
| 6 | `ask` off-interactive | **Per-channel / per-type configurable** fallback |
| 7 | Skill collision | **Reject** — platform names are reserved; names unique within an owner |
| 8 | Scope token | **DB enum migrated to `platform`** (from `global`) |
| 9 | Credentials at rest | Plaintext for now, masked in API responses |
| 10 | User secrets | New `user_secrets` table, ownership-scoped |
| 11 | Skill update ack | **Per user** (`user_skill_acks`) |
| 12 | MCP toggle | Drop the `agents.mcp_enabled` master; per-(agent, server) bindings are truth |
| 13 | Permission keys | **Admin-authored** catalog; the binary self-heals tool definitions only |
| 14 | `models.is_default` | Removed after backfill; per-type default supersedes it |
| 15 | `ask` "always allow" | Persisted per agent as an instance permission override |
| 16 | Providers | OpenAI-compatible only |
| 17 | Tool naming | `load_skill`, `manage_skill`, `download_media`, `upload_media` |
| 18 | Agent-authored skills | User-scoped/shared; `manage_skill` default `ask`; auto-enabled for the authoring agent only |

---

## I. Ontology — three entities, three planes

```
DEFINITION PLANE            scope = platform | user   (pure "what it is")
  Model(provider + params) · Skill(SKILL.md package) · McpServer · BuiltinTool
        ▲ user-owned entries carry the user's credentials

POLICY PLANE (platform)     AgentType = a platform-authored behavior blueprint
  prompt · allowed-model set + default/lock · capability baseline
  · permission baseline · modes · per-channel fallbacks · max_rounds

SELECTION PLANE (user)      Agent = an instance of exactly one AgentType
  chosen model (from the type's allowed set) · per-capability overrides
  · permission overrides · credentials for user-owned definitions
  · personalization files: AGENT.md / SOUL.md / USER.md / MEMORY.md
```

This is the spec's "two dimensions, two layers" made concrete: Dimension 1 is
the **Definition plane** (platform catalog + user catalog); Dimension 2 is the
**Binding planes** (platform policy on the AgentType, user selection on the
Agent).

---

## II. Axioms

1. **Ownership = mutability.** The platform owns definitions and AgentTypes.
   Users own Agents and their selections. A user never edits a platform
   definition; to change one they explicitly duplicate it into their own
   user-scoped library. There is no automatic fork.
2. **Definitions are live and single-homed; bindings are overrides.**
   Effective state is computed at read time. No copies, no drift, no migration
   when the platform fixes a definition.
3. **Precedence is total:** `lock (platform policy) > instance override (user)
   > type default (platform)`. An explicit user choice is never silently
   rewritten; only the un-overridden default moves.
4. **Credentials follow ownership** and live on the definition, never copied
   into bindings.
5. **Prompts are type-owned.** They are not capabilities, so "fork" never
   applied. User personalization is additive context (AGENT.md / SOUL.md).
6. **Enablement ≠ permission.** "Is it present?" (`on`/`off`) and "may it run,
   and must it ask?" (`allow`/`ask`/`deny`) are orthogonal axes.

---

## III. Entity model

### III.1 Definitions (Definition plane)

Each definition is tagged `scope = platform | user`; user definitions carry an
owner. Definitions are the only place credentials live.

- **Model**: belongs to a provider connection (base URL + credentials); carries
  context window, max output tokens, thinking switch/effort, sampling params.
- **Skill**: a file package (`SKILL.md` + resources). Platform skills are
  **versioned** (draft/published); user skills are overwritten in place.
- **McpServer**: transport (`http`/`sse`), URL, headers (credentials).
- **BuiltinTool**: platform-only. Tool **definitions** (description,
  parameters) self-heal from the running binary; **permission keys** are
  admin-authored (decision 13).

### III.2 AgentType (Policy plane)

A first-class platform-owned record with two kinds:

- **conversational** — a user-facing agent blueprint. Name, description,
  `prompt`, `default_mode`, `mode_policy`, `channel_fallbacks`, `max_rounds`,
  an allowed model set, and a capability baseline.
- **role** — an internal, single-purpose blueprint (`title`, `summarize`,
  `background`, `subagent`, `general`, `explore`, `scout`). Same shape; the
  runtime resolves it directly instead of instantiating a user Agent.

`plan`/`build` are **modes** on a conversational type, not separate types. Each
mode may carry its own tool baseline via `mode_policy`.

### III.3 Agent (Selection plane)

An instance of exactly one conversational AgentType. Holds: chosen model (from
the type's allowed set), per-capability overrides, permission overrides,
credentials references for user-owned definitions, and personalization files.

---

## IV. Resolution algorithm

Implemented once (shared helper), consumed by nanobus and nanosec.

Enablement is resolved across three levels, highest precedence first:

1. **Definition-plane global lock** (`builtin_tools`/`skills`/`mcp_servers.locked`)
   — admin policy, **absolute**: it forces availability for every type and
   agent and cannot be overridden.
2. **Agent-type baseline** (`agent_type_capabilities.locked` / `default_enabled`)
   — the platform policy plane, edited on the Agent Types page.
3. **Per-agent override** (`agent_type_overrides.capabilities`).
4. **Global default** (`*.default_enabled`) — the fallback for a type with no
   binding row; edited in the Capability Center.

```
effective(agent, kind, ref):
    def  = definition[kind, ref]              # global default + admin global lock
    base = agent_type_capabilities[agent.type_id, kind, ref]
    over = agent_capabilities[agent.id, kind, ref]
    if def.locked == "on":   return true      # definition-plane lock is absolute
    if def.locked == "off":  return false
    if base != nil:
        if base.locked == "on":  return true
        if base.locked == "off": return false
        if over != nil: return over.enabled
        return base.default_enabled
    if over != nil: return over.enabled
    return def.default_enabled

effectiveModel(agent):
    allowed = agent_type_models[agent.type_id]
    if allowed.default.locked: return allowed.default.model_id
    return valid(agent.model_id ∈ allowed) ?? allowed.default.model_id

permission(tool, agent, mode, channel):
    rules  = (type.mode_policy[mode] ?? base.permissions) ++ instance.permissions
    action = last rule whose pattern wildcard-matches tool
             ?? permission_keys[tool].default_action
    if action == "ask" and not interactive(channel):
        return type.channel_fallbacks[channel] ?? "deny"
    return action
```

**Wildcards** match tool names: `*` glob (`mcp__server__*`, `*_media`, exact
names). **Path rule:** `write`/`edit` are denied on `paths.SkillsDir` so the
only route into managed skills is `manage_skill`.

---

## V. Capability types under the model

**Models.** The AgentType declares the allowed set and a default (optionally
locked). The Agent picks within the set. "Type-level beats instance" is exactly
`locked`; there is no separate free-text override.

**Skills.** Definitions are live. A type may set `pin_version` and/or
`require_update_confirmation`; otherwise platform updates apply on reload.
Acknowledgement is **per user** (decision 11); effective version is
`type.pin_version ?? user_ack ?? latest_published`.

**MCP.** Definitions (platform + user) with credentials by ownership. The
definition-plane default is edited in the Capability Center; the AgentType
baseline overrides it per type; the Agent toggles per server. There is no master
switch (decision 12); the chat quick-toggle writes the same instance bindings
the config page reads.

**Built-in Tools.** Platform-only definitions. Enablement and permissions are
per type and per agent, with a definition-plane global default (Capability
Center) underneath. Permission keys are admin-authored; tool definitions
self-heal from the binary without overwriting admin state.

---

## VI. Permissions

Ordered rules `{pattern → allow|ask|deny}` merged type-then-instance with
last-match-wins. `ask` emits an approval prompt; "always allow" persists as an
instance override (decision 15). On non-interactive channels the type's
`channel_fallbacks` decides (default `deny`). Enablement remains a separate
boolean. Plan mode's tool set is the type's `mode_policy` baseline (the
hardcoded read-only set is only a fallback).

---

## VII. Skill lifecycle & agent authoring

- **Platform skills**: admin-authored, versioned, `draft`→`published`. Live by
  default; pin/confirm is an opt-in per-type policy.
- **User skills**: authored in the portal or by an agent; overwritten in place;
  no version/publish flow.
- **Collision**: names are unique; platform names are reserved and creation
  against a reserved/duplicate name is **rejected** (decision 7).
- **Agent authoring** goes through `manage_skill`, never raw file writes:
  validate (slug, frontmatter, path safety, extension/byte quotas, secret
  scan) → persist user-scoped (`origin=agent`) → auto-enable the authoring
  agent → reconcile → audit with a content hash. Default permission `ask`.
  Skill content is data injected via tool output, never authority; it cannot
  alter prompts, permissions, bindings, or AgentTypes. Scripts a skill
  references run under normal `bash` permissions.

---

## VIII. Credentials & secrets

| Item | Who supplies | Where stored |
|---|---|---|
| Platform MCP / Model | Platform | Definition (platform scope); users supply nothing |
| User MCP / Model | User | On the user-scoped definition |
| Skill secret values | User | `user_secrets`, keyed by `(user, kind, ref, key)` |

Skills only **declare** required secret keys in frontmatter; values never live
in `SKILL.md`. All credential fields are masked in API responses and never
returned to the browser; only the runtime agent receives them.

---

## IX. Naming conventions

- Tool names are **verb_noun**: `load_skill`, `manage_skill`, `download_media`,
  `upload_media` (alongside existing `read`, `write`, `edit`, `append_note`).
- The capability **kind** `skill` (the SKILL.md catalog) is distinct from the
  **tool** `load_skill`; they must not be conflated.
- The canonical scope token is **`platform`** (DB enum migrated from `global`).

---

## X. Error-proofing invariants

1. Bindings may reference missing definitions; resolution tolerates absence and
   dangling bindings are pruned on catalog delete.
2. User overrides are sticky; platform edits never rewrite them.
3. Total precedence; `locked` always wins.
4. Model choice ⊆ the type's allowed set, enforced at write **and** resolve.
5. Secrets live only on definitions/`user_secrets`, are ownership-scoped, and
   never reach the browser.
6. Skill materialization keeps a manifest plus version pin; path safety is
   enforced; collisions are rejected.
7. Binary `SyncBuiltinTools` never overwrites admin-owned fields.
8. Capability reloads hot-swap atomically.
9. Every mutation is audited.
10. Protocol changes bump nanoprotocol before consumers change.

---

## XI. How this supersedes the original spec

| Original spec item | Resolution here |
|---|---|
| Copy-then-fork / no propagation | Replaced by live resolve + total precedence; `lock`/`pin` is the only freeze. |
| "One-time distribution + manual confirmation" | A per-type `pin_version`/`require_update_confirmation` policy over live definitions; per-user acks. |
| Prompt non-overridable "exception" | Prompts are type-owned; they were never capabilities, so no exception exists. |
| Undefined "Agent type" | First-class `agent_types`; roles are role types; plan/build are modes. |
| Model override priority | Type allowed-set + default/lock; the agent picks within it; no free-text override. |
| Boolean enable vs permissions | Enablement and permission are orthogonal; permissions are allow/ask/deny. |
| Skill credentials undefined | Skills declare keys; values live in `user_secrets`. |
| `global` vs `platform` | One canonical token: `platform`. |
| MCP quick-toggle source of truth | Per-(agent, server) instance bindings. |
