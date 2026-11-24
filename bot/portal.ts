/**
 * Same portal call Doorline uses for Classe 300X / Home Touch.
 * The password is a function argument and is not stored.
 * Unlock is a panel-bus pulse in the app, not an HTTP route, so this client
 * does not invent one.
 */

export interface DoorPlant {
  id: string
  name: string
}

export interface PortalReply {
  ok: boolean
  status: number
  message: string
  token?: string
  plants?: DoorPlant[]
}

export interface MissedCall {
  id: string
  at: string
}

export interface DoorPortal {
  signIn(email: string, password: string, project: 'C3X' | 'MHT'): Promise<PortalReply>
  plants(token: string, project: 'C3X' | 'MHT'): Promise<PortalReply>
  missed(token: string, project: 'C3X' | 'MHT'): Promise<MissedCall[]>
}

const AGENTS = {
  C3X: { userAgent: 'doorentryforc300x-ios-1.13.6', appVersion: '1.13.6' },
  MHT: { userAgent: 'doorentryforHOMETOUCH-ios-1.13.6', appVersion: '1.13.6' },
} as const

async function readJson(res: Response): Promise<unknown> {
  const text = await res.text()
  if (!text) return null
  try {
    return JSON.parse(text) as unknown
  } catch {
    return null
  }
}

function tokenIn(body: unknown, header: string | null): string | undefined {
  if (header) return header
  if (body && typeof body === 'object' && 'auth_token' in body) {
    const value = (body as { auth_token?: unknown }).auth_token
    if (typeof value === 'string' && value) return value
  }
  return undefined
}

function plantsIn(body: unknown): DoorPlant[] {
  const rows = Array.isArray(body) ? body : body && typeof body === 'object' && Array.isArray((body as { plants?: unknown }).plants) ? (body as { plants: unknown[] }).plants : []
  const out: DoorPlant[] = []
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue
    const rec = row as { id?: unknown; plantID?: unknown; name?: unknown; label?: unknown }
    const id = typeof rec.id === 'string' ? rec.id : typeof rec.plantID === 'string' ? rec.plantID : ''
    if (!id) continue
    const name = typeof rec.name === 'string' ? rec.name : typeof rec.label === 'string' ? rec.label : id
    out.push({ id, name })
  }
  return out
}

export function livePortal(): DoorPortal {
  return {
    async signIn(email, password, project) {
      const profile = AGENTS[project]
      const res = await fetch('https://www.myhomeweb.com/eliot/users/sign_in', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json',
          prj_name: project,
          'user-agent': profile.userAgent,
        },
        body: JSON.stringify({
          username: email,
          password,
          rememberMe: true,
          appVersion: profile.appVersion,
          registrationId: '',
        }),
      })
      const body = await readJson(res)
      if (res.status === 401 || res.status === 403) {
        return { ok: false, status: res.status, message: 'That email or password was not accepted.' }
      }
      if (res.status < 200 || res.status >= 300) {
        const warning = res.headers.get('warning') ?? ''
        return { ok: false, status: res.status, message: warning || `The portal answered HTTP ${res.status}.` }
      }
      return { ok: true, status: res.status, message: 'signed in', token: tokenIn(body, res.headers.get('auth_token')), plants: plantsIn(body) }
    },
    async plants(token, project) {
      const res = await fetch('https://www.myhomeweb.com/eliot/plants', {
        headers: {
          accept: 'application/json',
          prj_name: project,
          'user-agent': AGENTS[project].userAgent,
          auth_token: token,
          authorization: `Bearer ${token}`,
        },
      })
      const warning = res.headers.get('warning') ?? ''
      if (res.status === 401 || /session expired/i.test(warning)) {
        return { ok: false, status: res.status, message: warning || 'User not logged or session expired' }
      }
      if (res.status < 200 || res.status >= 300) {
        return { ok: false, status: res.status, message: warning || `The portal answered HTTP ${res.status}.` }
      }
      const body = await readJson(res)
      return { ok: true, status: res.status, message: 'plants', plants: plantsIn(body) }
    },
    async missed() {
      return []
    },
  }
}
