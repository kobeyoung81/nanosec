// Fill the two demo accounts with data that makes the console look like a working
// team rather than an empty shell.
//
//   node seed.mjs --account both --stage all
//   node seed.mjs --account zh --stage talk --reset
//
// Stages: accounts → groups → agents → library → talk. Each stage is idempotent
// and skips what already exists, so a re-run repairs rather than duplicates.
import { chromium } from 'playwright'
import { api, token, U } from './lib/api.mjs'
import { login, sendTurn, openAgent, newConversation, waitIdle } from './lib/browser.mjs'
import { ACCOUNTS, BASE_URL, CONTENT, TALKS, WORKS } from './lib/personas.mjs'
import { templates } from './lib/docs.mjs'
import { showcase } from './lib/showcase.mjs'

const argv = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = argv.findIndex((a) => a === `--${name}` || a.startsWith(`--${name}=`))
  if (i < 0) return fallback
  const tok = argv[i]
  if (tok.includes('=')) return tok.slice(tok.indexOf('=') + 1)
  const next = argv[i + 1]
  return next && !next.startsWith('--') ? next : true
}
const STAGE = arg('stage', 'all')
const WHO = arg('account', 'both')
const RESET = argv.includes('--reset')
const ADMIN = { email: process.env.DEMO_ADMIN_EMAIL || 'nanosec@nanosec.dev', password: process.env.DEMO_ADMIN_PASSWORD || 'Z34DMuybZ91HtMpgLhgH' }

const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 19)}]`, ...a)
const stages = ['accounts', 'groups', 'agents', 'library', 'talk']
const STAGE_LIST = String(STAGE).split(',')
const want = (s) => STAGE_LIST.includes('all') || STAGE_LIST.includes(s)

async function adminApi() {
  const t = await token(BASE_URL, ADMIN.email, ADMIN.password)
  return { api: api(BASE_URL, t.access_token), token: t }
}

async function ensureAccount(account, admin) {
  let session
  try {
    await fetch(`${BASE_URL}/api/auth/v1/register`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: account.email, password: account.password, display_name: account.displayName }),
    }).then(async (r) => {
      if (!r.ok && r.status !== 409) throw new Error(`register ${account.email}: ${r.status} ${(await r.text()).slice(0, 160)}`)
    })
    session = await token(BASE_URL, account.email, account.password)
  } catch (e) {
    throw new Error(`cannot sign in ${account.email}: ${e.message}`)
  }
  const user = api(BASE_URL, session.access_token)
  // The agent replies in the account's language; the UI language is a browser
  // preference, so the two have to be set separately.
  await user.put(`${U.user}/preferences`, { language: account.lang }).catch((e) => log('  preference failed:', e.message))
  if (admin) {
    await admin.api.patch(`${U.admin}/users/${session.user_id}/role`, { role: 'admin' }).catch((e) => log('  role:', e.message))
    await admin.api.patch(`${U.admin}/users/${session.user_id}/tier`, { tier: 'ultra' }).catch((e) => log('  tier:', e.message))
  }
  log(`account ${account.email} ready (${session.user_id})`)
  return { ...account, api: user, userId: session.user_id }
}

async function ensureGroups(account) {
  const content = CONTENT[account.key]
  const existing = await account.api.get(`${U.user}/agent-groups`)
  const list = existing.groups || existing || []
  const byName = new Map(list.map((g) => [g.name, g]))
  const ids = {}
  for (const name of content.groups) {
    if (byName.has(name)) { ids[name] = byName.get(name).id; continue }
    const created = await account.api.post(`${U.user}/agent-groups`, { name })
    ids[name] = created.id
    log(`  group + ${name}`)
  }
  return ids
}

async function ensureAgents(account, groupIds) {
  const content = CONTENT[account.key]
  const existing = await account.api.get(`${U.user}/me/agents`)
  const list = existing.agents || existing || []
  const byName = new Map(list.map((a) => [a.display_name, a]))

  // A fresh account arrives with one agent literally called "My Agent": rename it
  // into the account's language instead of leaving an English row in Chinese data.
  const placeholder = byName.get('My Agent')
  if (placeholder) {
    const first = content.agents[0]
    await account.api.put(`${U.user}/agents/${placeholder.id}`, {
      display_name: first.name, group_id: groupIds[first.group], description: first.about,
    })
    byName.delete('My Agent')
    byName.set(first.name, { ...placeholder, display_name: first.name })
    log(`  agent ~ My Agent → ${first.name}`)
  }

  for (const a of content.agents) {
    if (byName.has(a.name)) continue
    await account.api.post(`${U.user}/agents`, {
      display_name: a.name, group_id: groupIds[a.group], description: a.about,
    })
    log(`  agent + ${a.name} (${a.group})`)
  }
}

async function waitForContainers(account, timeoutMs = 15 * 60_000) {
  const started = Date.now()
  for (;;) {
    const res = await account.api.get(`${U.user}/me/agents`)
    const list = res.agents || res || []
    const pending = list.filter((a) => String(a.status || '').toLowerCase().includes('provision'))
    if (pending.length === 0) return list
    if (Date.now() - started > timeoutMs) throw new Error(`${pending.length} agent(s) still provisioning after ${timeoutMs / 60000} min`)
    log(`  waiting: ${pending.length} agent(s) provisioning`)
    await new Promise((r) => setTimeout(r, 20_000))
  }
}

async function ensureLibrary(account) {
  const content = CONTENT[account.key]
  const works = WORKS[account.key]
  const lib = account.api
  const spaces = (await lib.get(`${U.library}/spaces`)).spaces || []
  // The library creates every account's first space as "我的空间" (a hardcoded
  // Chinese default, nanoartifacts/internal/store/spaces.go:83). Rename it for the
  // English account so the sidebar is not half-translated; the defect is recorded
  // in the blank-state audit either way.
  if (account.key === 'en') {
    const builtin = spaces.find((s) => s.name === '我的空间')
    if (builtin) {
      await lib.patch(`${U.library}/spaces/${builtin.id}`, { name: 'My space' })
      builtin.name = 'My space'
      log('  space ~ 我的空间 → My space')
    }
  }
  let space = spaces.find((s) => s.name === content.space)
  if (!space) {
    const created = await lib.post(`${U.library}/spaces`, { name: content.space })
    space = created.space
    log(`  space + ${content.space}`)
  }
  const tree = (await lib.get(`${U.library}/spaces/${space.id}/tree`)).nodes || []
  const folderId = {}
  for (const name of content.folders) {
    const hit = tree.find((n) => n.kind === 'folder' && n.title === name)
    if (hit) { folderId[name] = hit.id; continue }
    const created = await lib.post(`${U.library}/spaces/${space.id}/nodes`, { kind: 'folder', title: name })
    folderId[name] = created.node.id
    log(`  folder + ${name}`)
  }
  let made = 0
  for (const w of works) {
    const parentId = folderId[w.folder]
    const exists = tree.find((n) => n.parent_id === parentId && n.title === w.spec.title)
    if (exists) continue
    // One work is the showcase: full HTML with its own CSS and JS, which is
    // what the library's preview iframe (allow-scripts) is for.
    const html = w.showcase ? showcase(account.key) : templates[w.template](w.spec)
    await lib.post(`${U.library}/artifacts`, {
      space_id: space.id, parent_id: parentId, title: w.spec.title, kind: 'doc',
      html, note: account.key === 'zh' ? '演示数据 · 示例作品' : 'Demo data · sample work',
    })
    made++
  }
  log(`  works + ${made} (folders ${content.folders.length}, total ${works.length})`)
}

async function talk(account) {
  const talks = TALKS[account.key]
  const browser = await chromium.launch()
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 }, locale: account.uiLang, reducedMotion: 'reduce',
  })
  await ctx.addInitScript((lang) => {
    localStorage.setItem('nanoportal.theme', 'light')
    localStorage.setItem('nanoportal.lang', lang)
  }, account.uiLang)
  const page = await ctx.newPage()
  await login(page, BASE_URL, account.email, account.password)
  await page.waitForTimeout(4000)

  const failures = []
  for (const [i, t] of talks.entries()) {
    const label = `${i + 1}/${talks.length} ${t.agent}`
    try {
      await openAgent(page, t.agent)
      await newConversation(page)
      await sendTurn(page, t.prompt)
      if (t.followUp) {
        await waitIdle(page)
        await sendTurn(page, t.followUp.prompt)
      }
      log(`  talk ${label} ok`)
    } catch (e) {
      failures.push(`${label}: ${e.message}`)
      log(`  talk ${label} FAILED: ${e.message}`)
    }
  }
  await browser.close()
  if (failures.length) {
    log(`  ${failures.length} talk(s) failed:\n   - ${failures.join('\n   - ')}`)
    process.exitCode = 2
  }
}

// ── run ───────────────────────────────────────────────────────────────────
const targets = ACCOUNTS.filter((a) => WHO === 'both' || a.key === WHO)
const admin = STAGE === 'accounts' ? await adminApi() : null

for (const base of targets) {
  log(`=== ${base.key} (${base.email}) ===`)
  const account = await ensureAccount(base, admin)

  if (RESET) {
    log('  reset is manual: run reset.mjs first for a clean slate')
  }
  if (want('groups') || want('agents') || want('talk')) {
    const groupIds = await ensureGroups(account)
    if (want('agents') || want('talk')) {
      await ensureAgents(account, groupIds)
      await waitForContainers(account)
    }
  }
  if (want('library')) await ensureLibrary(account)
  if (want('talk')) await talk(account)
}
log('seed done')
