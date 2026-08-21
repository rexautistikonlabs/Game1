import { create } from 'zustand'
import { db, getSetting, setSetting } from '../db/db'
import { seedIfEmpty } from '../db/seed'

export type Theme = 'light' | 'dark'

export interface Toast {
  id: number
  message: string
  tone: 'success' | 'error' | 'info'
}

interface AppState {
  ready: boolean
  activeCompanyId: string | null
  theme: Theme
  toasts: Toast[]

  init: () => Promise<void>
  setActiveCompany: (id: string) => Promise<void>
  setTheme: (theme: Theme) => Promise<void>
  /** Re-reads persisted state — used after restoring a backup. */
  refresh: () => Promise<void>
  toast: (message: string, tone?: Toast['tone']) => void
  dismissToast: (id: number) => void
}

function applyTheme(theme: Theme) {
  document.documentElement.dataset.theme = theme
  document.documentElement.classList.toggle('dark', theme === 'dark')
}

let toastSeq = 0

/**
 * React StrictMode invokes effects twice in development, so `init` can be
 * called concurrently. Sharing one in-flight promise keeps seeding to a single
 * run — otherwise the example companies get inserted twice.
 */
let initPromise: Promise<void> | null = null

/**
 * Only genuinely global UI state lives here. Everything that belongs to the
 * database is read straight from Dexie with live queries, so there is never a
 * second copy of the truth to keep in sync.
 */
export const useApp = create<AppState>((set, get) => ({
  ready: false,
  activeCompanyId: null,
  theme: 'light',
  toasts: [],

  init: async () => {
    if (initPromise) return initPromise
    initPromise = (async () => {
      await seedIfEmpty()
      const theme = await getSetting<Theme>('theme', 'light')
      applyTheme(theme)

      const savedId = await getSetting<string | null>('activeCompanyId', null)
      const companies = await db.companies.orderBy('createdAt').toArray()
      const activeCompanyId =
        (savedId && companies.some((c) => c.id === savedId) ? savedId : companies[0]?.id) ?? null

      if (activeCompanyId !== savedId) await setSetting('activeCompanyId', activeCompanyId)
      set({ ready: true, theme, activeCompanyId })
    })()
    return initPromise
  },

  refresh: async () => {
    const companies = await db.companies.orderBy('createdAt').toArray()
    const savedId = await getSetting<string | null>('activeCompanyId', null)
    const activeCompanyId =
      (savedId && companies.some((c) => c.id === savedId) ? savedId : companies[0]?.id) ?? null
    const theme = await getSetting<Theme>('theme', get().theme)
    applyTheme(theme)
    set({ activeCompanyId, theme })
  },

  setActiveCompany: async (id) => {
    set({ activeCompanyId: id })
    await setSetting('activeCompanyId', id)
  },

  setTheme: async (theme) => {
    applyTheme(theme)
    set({ theme })
    await setSetting('theme', theme)
  },

  toast: (message, tone = 'success') => {
    const id = ++toastSeq
    set({ toasts: [...get().toasts, { id, message, tone }] })
    setTimeout(() => get().dismissToast(id), tone === 'error' ? 6000 : 3200)
  },

  dismissToast: (id) => set({ toasts: get().toasts.filter((t) => t.id !== id) }),
}))
