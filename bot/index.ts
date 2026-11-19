import { randomBytes } from 'node:crypto'
import { tr, type BotModule, type Lang, type Reply, type TickMessage } from '@robyrew/bot-sdk'
import type { DoorPlant, DoorPortal } from './portal.ts'

export interface DoorSession {
  token: string
  project: 'C3X' | 'MHT'
  plants: DoorPlant[]
}

export interface DoorDeps {
  portal: DoorPortal
  seal(plain: string): string
  open(packed: string): string
  /** Public origin, no trailing slash. The link page is /door/<token>. */
  publicBase: string
}

const help: Record<Lang, string> = {
  en: 'Each person connects their own entrance. /door sends a one-time link. The password is typed on that page, not in this chat. /door status lists your plants. Unlock names the entrance and waits for UNLOCK. It refuses in a group and refuses a plant that is not on your session.',
  ro: 'Fiecare își leagă propria intrare. /door trimite un link de unică folosință. Parola se scrie pe pagina aia, nu în chat. /door status listează intrările. Unlock numește intrarea și așteaptă UNLOCK. Refuză în grup și refuză o intrare care nu e pe sesiunea ta.',
  es: 'Cada persona conecta su propia entrada. /door envía un enlace de un solo uso. La contraseña se escribe en esa página, no en el chat. /door status lista tus plantas. Unlock nombra la entrada y espera UNLOCK. Rechaza en un grupo y rechaza una planta que no esté en tu sesión.',
}

function readSession(raw: string | null, open: (packed: string) => string): DoorSession | null {
  if (!raw) return null
  try {
    return JSON.parse(open(raw)) as DoorSession
  } catch {
    return null
  }
}

export function createDoorModule(deps: DoorDeps): BotModule {
  return {
    id: 'door',
    commands: ['door'],
    bucket: 'none',
    signIn: 'no',
    menu: (lang) => tr(lang, { en: 'Door', ro: 'Ușă', es: 'Puerta' }),
    help: (lang) => help[lang],
    async handle(input, api): Promise<Reply | Reply[] | null> {
      const session = readSession(api.get('session'), deps.open)
      const arg = input.args.trim().toLowerCase()
      if (arg === 'status') {
        if (!session) {
          return { kind: 'text', text: tr(input.lang, { en: 'No entrance is linked to this account.', ro: 'Nicio intrare nu e legată de contul ăsta.', es: 'No hay una entrada ligada a esta cuenta.' }) }
        }
        const listed = await deps.portal.plants(session.token, session.project)
        if (!listed.ok) return { kind: 'text', text: listed.message }
        const plants = listed.plants ?? []
        session.plants = plants
        api.set('session', deps.seal(JSON.stringify(session)))
        const names = plants.map((plant) => `${plant.name} (${plant.id})`).join('\n') || listed.message
        return { kind: 'text', text: names }
      }
      if (arg.startsWith('unlock')) {
        if (input.isGroup) {
          return { kind: 'text', text: tr(input.lang, { en: 'Unlock stays in a private chat.', ro: 'Unlock rămâne în chat privat.', es: 'Unlock se queda en un chat privado.' }) }
        }
        if (!session || session.plants.length === 0) {
          return { kind: 'text', text: tr(input.lang, { en: 'No entrance is linked to this account.', ro: 'Nicio intrare nu e legată de contul ăsta.', es: 'No hay una entrada ligada a esta cuenta.' }) }
        }
        const plantId = input.args.trim().split(/\s+/)[1] || session.plants[0]?.id
        const plant = session.plants.find((item) => item.id === plantId)
        if (!plant) {
          return { kind: 'text', text: tr(input.lang, { en: 'That entrance is not on your session.', ro: 'Intrarea asta nu e pe sesiunea ta.', es: 'Esa entrada no está en tu sesión.' }) }
        }
        return {
          kind: 'confirm',
          phrase: 'UNLOCK',
          payload: plant.id,
          prompt: tr(input.lang, {
            en: `Unlock the door lock at ${plant.name} (${plant.id}). Reply UNLOCK.`,
            ro: `Descuie yale de la ${plant.name} (${plant.id}). Răspunde UNLOCK.`,
            es: `Abre la cerradura de ${plant.name} (${plant.id}). Responde UNLOCK.`,
          }),
        }
      }
      const token = randomBytes(18).toString('base64url')
      api.setFor(token, 'owner', input.userId)
      const base = deps.publicBase.replace(/\/$/, '')
      const url = base ? `${base}/door/${token}` : ''
      const prompt = tr(input.lang, {
        en: 'Open this page and sign in to your own entrance. The password stays on the page.',
        ro: 'Deschide pagina asta și intră în propria intrare. Parola rămâne pe pagină.',
        es: 'Abre esta página y entra en tu propia entrada. La contraseña se queda en la página.',
      })
      return {
        kind: 'text',
        text: url ? prompt : `${prompt}\n${token}`,
        links: url ? [{ url, label: 'Door' }] : undefined,
      }
    },
    async confirm(input, api, payload) {
      if (input.isGroup) {
        return { kind: 'text', text: tr(input.lang, { en: 'Unlock stays in a private chat.', ro: 'Unlock rămâne în chat privat.', es: 'Unlock se queda en un chat privado.' }) }
      }
      const session = readSession(api.get('session'), deps.open)
      const plant = session?.plants.find((item) => item.id === payload)
      if (!plant) {
        return { kind: 'text', text: tr(input.lang, { en: 'That entrance is not on your session.', ro: 'Intrarea asta nu e pe sesiunea ta.', es: 'Esa entrada no está en tu sesión.' }) }
      }
      return {
        kind: 'text',
        text: tr(input.lang, {
          en: `The portal session does not carry a lock pulse for ${plant.name}. The Doorline app sends that on the panel link.`,
          ro: `Sesiunea portalului nu duce pulsul yalei pentru ${plant.name}. Aplicația Doorline îl trimite pe legătura panoului.`,
          es: `La sesión del portal no lleva el pulso de la cerradura de ${plant.name}. La app Doorline lo envía por el enlace del panel.`,
        }),
      }
    },
    async tick(api, now): Promise<TickMessage[]> {
      const messages: TickMessage[] = []
      for (const userId of api.usersWith('session')) {
        const session = readSession(api.getFor(userId, 'session'), deps.open)
        if (!session?.token) continue
        const calls = await deps.portal.missed(session.token, session.project)
        const seen = new Set((api.getFor(userId, 'seen-calls') ?? '').split(',').filter(Boolean))
        const fresh = calls.filter((call) => !seen.has(call.id))
        if (fresh.length === 0) continue
        const chatId = api.privateChat(userId)
        if (!chatId) continue
        for (const call of fresh) seen.add(call.id)
        api.setFor(userId, 'seen-calls', [...seen].slice(-50).join(','))
        messages.push({
          userId,
          chatId,
          reply: {
            kind: 'text',
            urgent: true,
            text: `Missed call ${fresh[0]?.at ?? now.toISOString()}`,
          },
        })
      }
      return messages
    },
  }
}
