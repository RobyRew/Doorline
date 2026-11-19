import type { DoorPortal } from './portal.ts'
import type { DoorSession } from './index.ts'

export interface DoorHttpDeps {
  /** Reads and writes the host kv table. */
  get(userId: string, key: string): string | null
  set(userId: string, key: string, value: string): void
  del(userId: string, key: string): void
  portal: DoorPortal
  seal(plain: string): string
}

const PAGE = `<!DOCTYPE html><meta charset="utf-8"><title>Door</title>
<form method="post">
<label>Email <input name="email" type="email" autocomplete="username" required></label>
<label>Password <input name="password" type="password" autocomplete="current-password" required></label>
<label>Product <select name="project"><option value="C3X">Classe 300X</option><option value="MHT">Home Touch</option></select></label>
<button type="submit">Sign in</button>
</form>`

/** Serves the one-time link page. Returns null when the path is not a door link. */
export async function handleDoorHttp(method: string, path: string, body: URLSearchParams, deps: DoorHttpDeps): Promise<{ status: number; body: string } | null> {
  const match = path.match(/^\/door\/([A-Za-z0-9_-]+)$/)
  if (!match) return null
  const token = match[1] ?? ''
  const userId = deps.get(token, 'owner')
  if (!userId) return { status: 404, body: 'This link is spent.' }
  if (method === 'GET') return { status: 200, body: PAGE }
  if (method !== 'POST') return { status: 405, body: 'POST the form.' }
  const email = body.get('email')?.trim() ?? ''
  const password = body.get('password') ?? ''
  const project = body.get('project') === 'MHT' ? 'MHT' : 'C3X'
  if (!email || !password) return { status: 400, body: 'Email and password are required.' }
  const signed = await deps.portal.signIn(email, password, project)
  if (!signed.ok || !signed.token) return { status: signed.status || 401, body: signed.message }
  const session: DoorSession = { token: signed.token, project, plants: signed.plants ?? [] }
  deps.set(userId, 'session', deps.seal(JSON.stringify(session)))
  deps.del(token, 'owner')
  return { status: 200, body: 'Entrance linked. You can close this page. The password was not stored.' }
}
