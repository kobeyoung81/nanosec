// Walk every console route and record how empty it looks.
//
//   node audit.mjs --account zh --label after
//   node audit.mjs --email demo.blank@nanosec.dev --password … --label before
//
// Writes out/audit-<label>.json and one screenshot per route. "Empty" is decided
// by the strings the product itself prints when it has nothing to show, not by
// eyeballing — the same list runs before and after the seed.
import { chromium } from 'playwright'
import sharp from 'sharp'
import fs from 'node:fs'
import path from 'node:path'
import { BASE_URL, ACCOUNTS } from './lib/personas.mjs'
import { login } from './lib/browser.mjs'

const argv = process.argv.slice(2)
const arg = (n, d) => {
  const i = argv.findIndex((a) => a === `--${n}` || a.startsWith(`--${n}=`))
  if (i < 0) return d
  const t = argv[i]
  if (t.includes('=')) return t.slice(t.indexOf('=') + 1)
  return argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : true
}

const account = ACCOUNTS.find((a) => a.key === arg('account', 'zh')) || ACCOUNTS[0]
const email = arg('email', account.email)
const password = arg('password', account.password)
const label = arg('label', 'after')
const lang = arg('lang', account.uiLang)

// Strings the UI prints when a list has nothing in it, in both languages.
const EMPTY = [
  'No agents yet', 'No conversations yet', 'No scheduled tasks yet', 'This space is empty',
  'Nothing in this folder yet', 'No active alerts', 'No branches yet', 'No alerts yet',
  '没有智能体', '暂无会话', '没有正在进行的任务', '这个空间还是空的', '这个目录还没有内容',
  '当前没有告警', '暂无告警', '还没有分支', 'No data', '暂无数据',
]

const ROUTES = [
  ['agent', '/agent'],
  ['files', '/files'],
  ['me', '/me'],
  ['artifacts', '/artifacts'],
  ['admin-overview', '/admin/overview'],
  ['admin-components', '/admin/components'],
  ['admin-users', '/admin/users'],
  ['admin-configs', '/admin/configs'],
  ['admin-audit', '/admin/audit'],
  ['admin-conversations', '/admin/conversations'],
  ['admin-runtime', '/admin/runtime'],
  ['admin-models', '/admin/models'],
  ['admin-capabilities', '/admin/capabilities'],
  ['admin-agent-types', '/admin/agent-types'],
  ['admin-alerts', '/admin/alerts'],
  ['admin-directory', '/admin/directory'],
  ['admin-voice', '/admin/voice-input'],
]

const outDir = path.join('out', `audit-${label}`)
fs.mkdirSync(outDir, { recursive: true })

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US', reducedMotion: 'reduce' })
await ctx.addInitScript((l) => {
  localStorage.setItem('nanoportal.theme', 'light')
  localStorage.setItem('nanoportal.lang', l)
}, lang)
const page = await ctx.newPage()
await login(page, BASE_URL, email, password)
await page.waitForTimeout(3000)

const rows = []
for (const [slug, route] of ROUTES) {
  await page.goto(BASE_URL + route, { waitUntil: 'domcontentloaded', timeout: 30000 })
  await page.waitForTimeout(2600)
  const text = (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ')
  const hits = EMPTY.filter((s) => text.includes(s))
  const file = path.join(outDir, `${slug}.png`)
  await page.screenshot({ path: file })
  const { data, info } = await sharp(file).flatten({ background: '#ffffff' }).greyscale().raw().toBuffer({ resolveWithObject: true })
  const paper = data[0]
  let ink = 0
  for (let i = 0; i < data.length; i++) if (Math.abs(data[i] - paper) > 12) ink++
  rows.push({ slug, route, empty: hits, inkPct: +((ink / data.length) * 100).toFixed(2), chars: text.length })
  console.log(`${slug.padEnd(20)} ink ${String(((ink / data.length) * 100).toFixed(2)).padStart(5)}%  chars ${String(text.length).padStart(5)}  ${hits.length ? 'EMPTY: ' + hits.join(' | ') : ''}`)
}

fs.writeFileSync(path.join('out', `audit-${label}.json`), JSON.stringify({ label, email, at: new Date().toISOString(), rows }, null, 2))
await browser.close()
