// Remove the demo data and leave the two accounts in place.
//
//   node reset.mjs --account both            # agents, conversations, library
//   node reset.mjs --account zh --keep-library
//
// Everything here is scoped to the demo accounts: it never touches another
// account's rows, and it never deletes the accounts themselves (a re-run of
// seed.mjs re-creates the data).
import { api, token, U } from './lib/api.mjs'
import { BASE_URL, ACCOUNTS, CONTENT } from './lib/personas.mjs'

const argv = process.argv.slice(2)
const who = argv.includes('--account') ? argv[argv.indexOf('--account') + 1] : 'both'
const keepLibrary = argv.includes('--keep-library')
const targets = ACCOUNTS.filter((a) => who === 'both' || a.key === who)

for (const account of targets) {
  const session = await token(BASE_URL, account.email, account.password)
  const client = api(BASE_URL, session.access_token)
  console.log(`=== ${account.key} ===`)

  const raw = await client.get(`${U.user}/me/agents`)
  for (const agent of raw.agents || raw) {
    await client.del(`${U.user}/agents/${agent.id}`).catch((e) => console.log('  agent:', e.message))
    console.log(`  - agent ${agent.display_name}`)
  }

  if (!keepLibrary) {
    const spaces = (await client.get(`${U.library}/spaces`)).spaces || []
    for (const space of spaces) {
      await client.del(`${U.library}/spaces/${space.id}`).catch((e) => console.log('  space:', e.message))
      console.log(`  - space ${space.name}`)
    }
  }
}
console.log('reset done')
