// Take the screenshots the README and the docs use.
//
//   node shots.mjs --account zh --label readme
//   node shots.mjs --account both --themes light,dark
//
// Each shot is a (route recipe × theme × account). Output:
//   out/shots/<label>/<slug>-<theme>-<lang>.png   2020 px wide, 2x of the width
//                                                 the README actually renders
// The ink ratio is printed per shot: a route that renders as a white board fails
// loudly instead of quietly landing in a document.
import { chromium } from 'playwright'
import sharp from 'sharp'
import fs from 'node:fs'
import path from 'node:path'
import { BASE_URL, ACCOUNTS } from './lib/personas.mjs'
import { login, openAgent, openConversation } from './lib/browser.mjs'

const argv = process.argv.slice(2)
const arg = (n, d) => {
  const i = argv.findIndex((a) => a === `--${n}` || a.startsWith(`--${n}=`))
  if (i < 0) return d
  const t = argv[i]
  if (t.includes('=')) return t.slice(t.indexOf('=') + 1)
  return argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : true
}

const label = arg('label', 'shots')
const who = arg('account', 'both')
const themes = String(arg('themes', 'light,dark')).split(',')
const targets = ACCOUNTS.filter((a) => who === 'both' || a.key === who)
const outRoot = path.join('out', 'shots', label)

// A route may need a pose before it is worth photographing.
const POSES = {
  zh: { agents: '助理', space: '季度工作台' },
  en: { agents: 'Assistant', space: 'Quarterly workspace' },
}

const RECIPES = {
  workbench: async (page, c) => {
    await page.goto(`${BASE_URL}/agent`, { waitUntil: 'domcontentloaded' })
    await page.waitForTimeout(3000)
    await openAgent(page, c.agents[0])
    await openConversation(page, 0)
    await page.waitForTimeout(2500)
  },
  artifacts: async (page, c) => {
    await page.goto(`${BASE_URL}/artifacts`, { waitUntil: 'domcontentloaded' })
    const frame = await findFrame(page, '.nz-side')
    // The library remembers the last space; jump to the seeded one explicitly.
    await frame.locator('.nz-space-button').click().catch(() => {})
    await page.waitForTimeout(500)
    const option = frame.locator('.nz-space-menu [role=option]').filter({ hasText: c.space }).first()
    if (await option.count()) { await option.click(); await page.waitForTimeout(1200) }
    await frame.locator('[data-node-id]').first().click()
    await page.waitForTimeout(1200)
    const item = frame.locator('.nz-items button').first()
    if (await item.count()) await item.click()
    await page.waitForTimeout(3000)
  },
  'admin-users': async (page) => {
    await page.goto(`${BASE_URL}/admin/users`, { waitUntil: 'domcontentloaded' })
    await page.waitForTimeout(2000)
    const box = page.locator('input[placeholder]').first()
    await box.fill('demo.')
    await page.waitForTimeout(1200)
  },
}

const ROUTES = [
  ['workbench', '/agent'],
  ['artifacts', '/artifacts'],
  ['admin-overview', '/admin/overview'],
  ['admin-users', '/admin/users'],
  ['admin-audit', '/admin/audit'],
]

async function findFrame(page, selector) {
  for (let i = 0; i < 20; i++) {
    for (const f of page.frames()) {
      if (await f.locator(selector).count()) return f
    }
    await page.waitForTimeout(500)
  }
  return page.mainFrame()
}

async function inkRatio(file) {
  const { data, info } = await sharp(file).flatten({ background: '#ffffff' }).greyscale().raw().toBuffer({ resolveWithObject: true })
  const paper = data[0]
  let ink = 0
  for (let i = 0; i < data.length; i++) if (Math.abs(data[i] - paper) > 12) ink++
  return +((ink / data.length) * 100).toFixed(2)
}

const browser = await chromium.launch()
for (const account of targets) {
  for (const theme of themes) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, locale: 'en-US', reducedMotion: 'reduce' })
    await ctx.addInitScript(([t, l]) => {
      localStorage.setItem('nanoportal.theme', t)
      localStorage.setItem('nanoportal.lang', l)
    }, [theme, account.uiLang])
    const page = await ctx.newPage()
    await login(page, BASE_URL, account.email, account.password)
    await page.waitForTimeout(3000)

    const dir = path.join(outRoot, account.key)
    fs.mkdirSync(dir, { recursive: true })
    for (const [slug, route] of ROUTES) {
      try {
        if (RECIPES[slug]) await RECIPES[slug](page, POSES[account.key])
        else await page.goto(BASE_URL + route, { waitUntil: 'domcontentloaded' })
        await page.waitForTimeout(1800)
        await page.mouse.move(4, 4)
        const raw = path.join(dir, `_raw-${slug}-${theme}.png`)
        await page.screenshot({ path: raw })
        const out = path.join(dir, `${slug}-${theme}.png`)
        await sharp(raw).resize({ width: 2020, kernel: 'lanczos3' }).png({ compressionLevel: 9, effort: 10 }).toFile(out)
        fs.unlinkSync(raw)
        const ink = await inkRatio(out)
        const size = (fs.statSync(out).size / 1024).toFixed(0)
        console.log(`${account.key}/${theme} ${slug.padEnd(18)} ink ${String(ink).padStart(5)}%  ${size} KB`)
      } catch (e) {
        console.log(`${account.key}/${theme} ${slug.padEnd(18)} FAILED: ${e.message.split('\n')[0]}`)
        process.exitCode = 2
      }
    }
    await ctx.close()
  }
}
await browser.close()
