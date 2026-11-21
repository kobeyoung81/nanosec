// The only part that cannot be done over HTTP: sending a message and waiting for
// the turn to finish. Conversations live in the agent container, so the browser
// is the client the product actually ships.

const STOP = /^(Stop|停止)$/
const SEND = /^(Send|发送)$/

export async function login(page, base, email, password, { timeout = 45000 } = {}) {
  await page.goto(`${base}/login`, { waitUntil: 'domcontentloaded', timeout })
  await page.waitForSelector('input[type=email]', { timeout })
  await page.fill('input[type=email]', email)
  await page.fill('input[type=password]', password)
  await page.click('button[type=submit]')
  const started = Date.now()
  while (Date.now() - started < timeout) {
    if (!page.url().includes('/login')) return page.url()
    await page.waitForTimeout(400)
  }
  throw new Error(`login did not leave /login (still ${page.url()})`)
}

/** Wait until the composer is idle: no Stop button and the send button exists. */
export async function waitIdle(page, timeout = 90_000) {
  const stop = page.getByRole('button', { name: STOP })
  const started = Date.now()
  while (Date.now() - started < timeout) {
    if ((await stop.count()) === 0) return true
    await page.waitForTimeout(1000)
  }
  return false
}

/**
 * The agent may stop and ask structured questions before it acts (that is the
 * product's interview card, `data-question-record`). Pick the first option in
 * every question and submit, so a scripted turn can finish on its own.
 */
export async function answerQuestions(page, maxRounds = 3) {
  for (let round = 0; round < maxRounds; round++) {
    const submit = page.getByRole('button', { name: /^(提交|Submit)$/ }).first()
    if (!(await submit.count()) || !(await submit.isVisible())) return round > 0
    const record = page.locator('[data-question-record]').last()
    const items = record.locator('li')
    const count = await items.count()
    for (let i = 0; i < count; i++) {
      const opts = items.nth(i).locator('button')
      if (await opts.count()) await opts.first().click({ timeout: 3000 }).catch(() => {})
    }
    await submit.click({ timeout: 5000 }).catch(() => {})
    await page.waitForTimeout(1500)
  }
  return true
}

/** Send one message and wait for the agent's turn to finish. */
export async function sendTurn(page, text, { timeout = 120_000 } = {}) {
  // The workbench keeps a hidden composer next to the live one.
  const box = page.locator('textarea:visible').first()
  await box.waitFor({ state: 'visible', timeout: 30_000 })
  await box.fill(text)
  await page.waitForTimeout(300)
  const send = page.getByRole('button', { name: SEND }).first()
  if (await send.count()) await send.click()
  else await box.press('Enter')

  const stop = page.getByRole('button', { name: STOP })
  // The turn may finish before we look; absence right away is fine.
  for (let i = 0; i < 20; i++) {
    if ((await stop.count()) > 0) break
    await page.waitForTimeout(250)
  }
  const started = Date.now()
  while (Date.now() - started < timeout) {
    if ((await stop.count()) === 0) {
      // A turn can end by asking the user something instead of by finishing.
      if (await answerQuestions(page)) continue
      await page.waitForTimeout(1200) // let the final frame settle
      return
    }
    await page.waitForTimeout(1000)
  }
  throw new Error(`turn did not finish within ${timeout}ms: ${text.slice(0, 40)}`)
}

/** Pick an agent in the left dock by its visible name. */
export async function openAgent(page, name) {
  const row = page.locator('[data-agent-row]').filter({ hasText: name }).first()
  await row.waitFor({ state: 'visible', timeout: 20_000 })
  await row.click()
  await page.waitForTimeout(1200)
}

/** Open the nth conversation of the selected agent (0 = most recent). */
export async function openConversation(page, index = 0) {
  const rows = page.locator('[data-session-id]')
  await rows.first().waitFor({ state: 'visible', timeout: 20_000 })
  const count = await rows.count()
  if (!count) throw new Error('no conversation rows')
  await rows.nth(Math.min(index, count - 1)).click()
  await page.waitForTimeout(1500)
  return count
}

/** How many conversations the selected agent currently lists. */
export async function conversationCount(page) {
  return page.locator('[data-session-id]').count()
}

/** Start a fresh conversation for the selected agent. */
export async function newConversation(page) {
  const btn = page.getByRole('button', { name: /^(New conversation|新建会话)$/ }).first()
  if (await btn.count()) {
    await btn.click()
    await page.waitForTimeout(1200)
  }
}

/** Visible text of the whole page, whitespace-collapsed. */
export async function pageText(page) {
  return (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ').trim()
}
