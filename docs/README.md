# Documentation

Everything in `docs/` describes the system as it is built, or a design decision that
was actually taken. Where a document and the code disagree, the code wins — please
open an issue so the document can be fixed.

Start with the first three; the rest are reference.

## Start here

| Document | What it covers |
|---|---|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | How the system is put together: the eight services, who owns which prefix, the main flows, trust boundaries. **v6.0, 2026-11-11.** |
| [`DEPLOYMENT.md`](./DEPLOYMENT.md) | Compose, Swarm and Kubernetes; ports, environment variables, the init containers, operations. **v2.0, 2026-11-12.** |
| [`PRD.md`](./PRD.md) | What the product is for, who it is for, and what it deliberately is not. **v2.1.** |

## Operations

| Document | What it covers | Status |
|---|---|---|
| [`RELEASING.md`](./RELEASING.md) | The two layers of version — one per service, one for the super-repo — how `versions.lock` pins them, and how the manifests are rendered from it. | Current |
| [`CUTOVER.md`](./CUTOVER.md) | The runbook for moving a running stack to a new one: freeze, dump, restore, verify, roll back. Written for the person doing it at night. | Chinese, current |

## Services and data

| Document | What it covers | Status |
|---|---|---|
| [`P1-COLLECTION-MAP.md`](./P1-COLLECTION-MAP.md) | The collection-by-collection map from the old names and two databases to one database with a prefix per module. | Final |
| [`CAPABILITY_UNIFICATION_DESIGN.md`](./CAPABILITY_UNIFICATION_DESIGN.md) | How models, skills, MCP servers and built-in tools became one catalogue with one permission model. | Locked, v1.0 |

## Product surface

| Document | What it covers | Status |
|---|---|---|
| [`ACCOUNT_MANAGEMENT_DESIGN.md`](./ACCOUNT_MANAGEMENT_DESIGN.md) | Registration, credentials, sessions, channel and OAuth links, account pages. | Current, v1.3 |
| [`MANAGEMENT_PORTAL_DESIGN.md`](./MANAGEMENT_PORTAL_DESIGN.md) | The admin console: users, agents, configuration, catalogues, audit. | Current, v1.2 |
| [`WECHAT_MINI_PROGRAM_DESIGN.md`](./WECHAT_MINI_PROGRAM_DESIGN.md) | The WeChat Mini Program and its backend: login, account, subscription, preferences. | Current, v2.1 |

## Agent features

| Document | What it covers | Status |
|---|---|---|
| [`AGENT_HOME_DESIGN.md`](./AGENT_HOME_DESIGN.md) | Agent home and workspace with several agents per person: files, prompts, per-agent state. | Implemented, v1.0 |
| [`AGENT_HOME_IMPLEMENTATION.md`](./AGENT_HOME_IMPLEMENTATION.md) | The implementation plan for the above. Superseded in part by the multi-agent work. | Implemented |
| [`AGENT_GROUPS_DESIGN.md`](./AGENT_GROUPS_DESIGN.md) | Agent groups: shared configuration across agents, routing by group. | Implemented, 2026-10-24 |
| [`BUNDLED_SKILLS_DESIGN.md`](./BUNDLED_SKILLS_DESIGN.md) | Bundled skills: catalogue in the database, seeded from code, versioned. | Implemented |
| [`BUNDLED_PROMPTS_DESIGN.md`](./BUNDLED_PROMPTS_DESIGN.md) | The same for the built-in agent types' system prompts. | Implemented |
| [`VOICE_INPUT_DESIGN.md`](./VOICE_INPUT_DESIGN.md) | Dictation from the composer: the three recognition layers and where the audio is (not) stored. | Implemented, 2026-10-10 |

## Engineering notes

| Document | What it covers | Status |
|---|---|---|
| [`LEGACY_BROWSER_COMPATIBILITY.md`](./LEGACY_BROWSER_COMPATIBILITY.md) | What the console does without modern CSS and JavaScript features, and what it degrades to. | Current, v1.0 |
