# Demo environment

The two demo accounts the screenshots and the design documents are taken from:
one whose data is Chinese, one whose data is English, both on the dev stack. This
directory is the tooling behind `docs/assets/*.png` and the work-library documents
that describe the environment.

The full manual — accounts, what data exists, how to reset, what the screenshots
are — lives in the work library ("NanoSec 演示与截图环境手册"). This file is the
part a developer needs at the terminal.

## What it does

| Script | What it does |
|---|---|
| `seed.mjs` | Creates the groups, agents, conversations, scheduled tasks, files and library works for one or both accounts. Idempotent: re-running repairs instead of duplicating. |
| `reset.mjs` | Deletes the demo agents and library spaces. The accounts stay. |
| `repair.mjs` | Finishes turns that stopped to ask the user structured questions. |
| `verify.mjs` | Counts what exists (agents, conversations, library nodes) and checks the two panels that only exist in the browser. |
| `shots.mjs` | Takes the screenshots: five routes × theme × account, 2020 px wide. |
| `audit.mjs` | Walks every console route and records how empty it looks, before and after seeding. |

## Running it

```bash
cd scripts/demo
npm install                      # playwright + sharp, dev-only; CI does not run this
cp .env.demo.example .env.demo   # fill in the passwords
set -a && . ./.env.demo && set +a

node audit.mjs --account en --label before     # 17 routes, ~2 min
node seed.mjs  --account both --stage all      # ~20 min: 24 conversations
node verify.mjs --account both
node shots.mjs --account both --label readme   # ~6 min, 20 images
```

`seed.mjs --stage` takes `accounts`, `groups`, `agents`, `library`, `talk`, or a
comma-separated list (`--stage groups,agents`), so a partial re-run is cheap.

## Three things that bite

- **An account's language is two settings.** The agent replies in
  `preferences.language` (server-side, per account); the console's UI language is
  `localStorage['nanoportal.lang']` in the browser. `seed.mjs` sets the first,
  `shots.mjs` sets the second. Set only one and the screenshot is half-translated.
- **A turn can end by asking questions, not by finishing.** When the agent needs
  input it renders a question card and waits; a scripted turn then looks hung.
  `repair.mjs` answers the first option in every question and submits.
- **A failed turn merges into the last conversation.** "New conversation" is a
  no-op while a turn is still running, so a timed-out turn can fold into the
  previous conversation instead of starting a new one. If a run ends short,
  re-run `seed.mjs --stage talk` or top up by hand — do not assume the count.

## Dependencies

`playwright` and `sharp` only. Nothing here is imported by the product, and no
package in the product imports it.
