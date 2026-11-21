// Is the demo data actually there? Counts through the APIs, plus the two panels
// that only exist in the browser (scheduled tasks and the file list).
//
//   node verify.mjs --account both --expect agents=8
import { chromium } from 'playwright'
import { api, token, U } from './lib/api.mjs'
import { BASE_URL, ACCOUNTS, CONTENT } from './lib/personas.mjs'
import { login, openAgent } from './lib/browser.mjs'

const argv = process.argv.slice(2)
const arg = (n, d) => {
  const i = argv.findIndex((a) => a === `--${n}` || a.startsWith(`--${n}=`))
  if (i < 0) return d
  const t = argv[i]
  if (t.includes('=')) return t.slice(t.indexOf('=') + 1)
  return argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : true
}
const who = arg('account', 'both')
const expectAgents = Number(String(arg('agents', '8')))
const targets = ACCOUNTS.filter((a) => who === 'both' || a.key === who)

let failures = 0
const check = (ok, label, detail = '') => {
  if (!ok) failures++
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}${detail ? '  ' + detail : ''}`)
}

const browser = await chromium.launch()
for (const account of targets) {
  console.log(`\n=== ${account.key} (${account.email}) ===`)
  const session = await token(BASE_URL, account.email, account.password)
  const apiUser = api(BASE_URL, session.access_token)

  const rawAgents = await apiUser.get(`${U.user}/me/agents`)
  const agents = rawAgents.agents || rawAgents
  check(agents.length === expectAgents, `agents = ${agents.length} (want ${expectAgents})`)
  const pending = agents.filter((a) => String(a.status || '').toLowerCase().includes('provision'))
  check(pending.length === 0, 'no agent left provisioning', pending.length ? pending.map((a) => a.display_name).join(', ') : '')

  let sessions = 0
  for (const agent of agents) {
    const res = await apiUser.get(`${U.user}/agents/${agent.id}/sessions`)
    const list = res.sessions || res || []
    sessions += list.length
  }
  check(sessions >= 10, `conversations = ${sessions} (want >= 10)`)

  const spaces = (await apiUser.get(`${U.library}/spaces`)).spaces || []
  const space = spaces.find((s) => s.name === CONTENT[account.key].space)
  check(!!space, `library space "${CONTENT[account.key].space}"`)
  if (space) {
    const nodes = (await apiUser.get(`${U.library}/spaces/${space.id}/tree`)).nodes || []
    const folders = nodes.filter((n) => n.kind === 'folder').length
    const works = nodes.filter((n) => n.kind !== 'folder').length
    check(folders === 3, `library folders = ${folders}`)
    check(works >= 12, `library works = ${works}`)
  }

  // The two panels that only exist in the browser.
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: account.uiLang, reducedMotion: 'reduce' })
  await ctx.addInitScript((l) => { localStorage.setItem('nanoportal.lang', l); localStorage.setItem('nanoportal.theme', 'light') }, account.uiLang)
  const page = await ctx.newPage()
  await login(page, BASE_URL, account.email, account.password)
  await page.waitForTimeout(3500)
  await openAgent(page, CONTENT[account.key].agents[0].name)
  const text = (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ')
  check(!/No scheduled tasks yet|没有正在进行的任务|暂无定时任务/.test(text), 'tasks panel has content (after opening the Tasks tab)')
  await page.getByRole('button', { name: /^(Tasks|任务)$/ }).first().click().catch(() => {})
  await page.waitForTimeout(1500)
  const tasksText = (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ')
  check(!/No scheduled tasks yet|暂无定时任务|没有定时任务/.test(tasksText), 'tasks panel is not empty')
  await ctx.close()
}
await browser.close()
console.log(`\n${failures ? `${failures} check(s) failed` : 'all checks passed'}`)
process.exitCode = failures ? 1 : 0
