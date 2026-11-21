// Thin REST client for the demo seed.
//
// Everything the demo accounts need except conversations is reachable over HTTP:
// the portal's user API, the admin API, and the work library (which takes the same
// access token as a bearer). Conversations come from the agent container, so they
// are driven through the UI instead (see lib/browser.mjs).

export async function token(base, email, password) {
  const res = await fetch(`${base}/api/auth/v1/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`login ${email}: ${res.status} ${text.slice(0, 200)}`)
  return JSON.parse(text)
}

export function api(base, accessToken) {
  async function call(method, path, body) {
    const res = await fetch(base + path, {
      method,
      headers: {
        authorization: `Bearer ${accessToken}`,
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    })
    const text = await res.text()
    let json = null
    try { json = text ? JSON.parse(text) : null } catch { /* non-JSON error page */ }
    if (!res.ok) {
      const detail = json?.error || text.slice(0, 200)
      const err = new Error(`${method} ${path}: ${res.status} ${detail}`)
      err.status = res.status
      throw err
    }
    return json
  }

  return {
    call,
    get: (p) => call('GET', p),
    post: (p, b) => call('POST', p, b),
    put: (p, b) => call('PUT', p, b),
    patch: (p, b) => call('PATCH', p, b),
    del: (p) => call('DELETE', p),
  }
}

// Path prefixes the console proxies (nanoportal/deploy/nginx.conf).
export const U = {
  user: '/api/user/v1',
  admin: '/api/admin/v1',
  library: '/nanoartifacts/api/v1',
}
