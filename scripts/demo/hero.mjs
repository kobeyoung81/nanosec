// The conversation the README opens with has to look like the product working.
// Give the agent the facts first, then ask for the judgement.
import { chromium } from 'playwright'
import { BASE_URL, ACCOUNTS, CONTENT } from './lib/personas.mjs'
import { login, sendTurn, openAgent, newConversation } from './lib/browser.mjs'

const PROMPT = {
  zh: '这个季度我们做了三件事：一，控制台换成石墨主题，深色下不再是黑乎乎一团；二，图标收敛成一套线稿 n，五个尺寸同一份几何；三，文档资产加了门禁，死图进不来了。帮我按"对用户的影响"排个优先级，每条一句理由。',
  en: 'Three things shipped this quarter: one, the console moved to the graphite theme so dark mode is no longer one flat black sheet; two, the icon set collapsed to a single line-art n across five sizes; three, docs assets got a gate so dead images cannot come back. Rank them by impact on users, one line of reasoning each.',
}

const browser = await chromium.launch()
for (const account of ACCOUNTS) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: account.uiLang, reducedMotion: 'reduce' })
  await ctx.addInitScript((l) => { localStorage.setItem('nanoportal.lang', l); localStorage.setItem('nanoportal.theme', 'light') }, account.uiLang)
  const page = await ctx.newPage()
  await login(page, BASE_URL, account.email, account.password)
  await page.waitForTimeout(3500)
  const agent = { zh: '助理', en: 'Assistant' }[account.key]
  await openAgent(page, agent)
  await newConversation(page)
  try {
    await sendTurn(page, PROMPT[account.key], { timeout: 150_000 })
    console.log(account.key, 'hero conversation OK')
  } catch (e) {
    console.log(account.key, 'FAILED:', e.message.split('\n')[0])
  }
  await ctx.close()
}
await browser.close()
