// A turn can end by asking the user structured questions instead of finishing.
// This walks every conversation of the demo accounts, answers anything still
// pending, and lets the turn complete — so a half-run seed can be repaired
// without creating duplicate conversations.
import { chromium } from 'playwright'
import { BASE_URL, ACCOUNTS, CONTENT } from './lib/personas.mjs'
import { login, openAgent, waitIdle } from './lib/browser.mjs'

const who = process.argv.includes('--account') ? process.argv[process.argv.indexOf('--account') + 1] : 'both'
const targets = ACCOUNTS.filter((a) => who === 'both' || a.key === who)

const browser = await chromium.launch()
for (const account of targets) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: account.uiLang, reducedMotion: 'reduce' })
  await ctx.addInitScript((l) => { localStorage.setItem('nanoportal.lang', l); localStorage.setItem('nanoportal.theme', 'light') }, account.uiLang)
  const page = await ctx.newPage()
  await login(page, BASE_URL, account.email, account.password)
  await page.waitForTimeout(3500)

  for (const agent of CONTENT[account.key].agents) {
    await openAgent(page, agent.name)
    const rows = page.locator('[data-session-id]')
    const n = await rows.count()
    for (let i = 0; i < n; i++) {
      await rows.nth(i).click()
      await page.waitForTimeout(1500)
      const submit = page.getByRole('button', { name: /^(提交|Submit)$/ }).first()
      if ((await submit.count()) && (await submit.isVisible())) {
        const record = page.locator('[data-question-record]').last()
        const items = record.locator('li')
        const count = await items.count()
        for (let q = 0; q < count; q++) {
          const opts = items.nth(q).locator('button')
          if (await opts.count()) await opts.first().click({ timeout: 3000 }).catch(() => {})
        }
        await submit.click({ timeout: 5000 }).catch(() => {})
        console.log(`${account.key}/${agent.name} #${i}: answered ${count} question(s)`)
        await page.waitForTimeout(2000)
        await waitIdle(page, 120_000)
      }
    }
  }
  await ctx.close()
}
await browser.close()
console.log('repair done')
