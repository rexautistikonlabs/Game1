import { useLiveQuery } from 'dexie-react-hooks'
import { db } from '../db/db'
import { useApp } from './useApp'
import type { Client, Company, Document, Expense } from '../types'

/** Every company in the switcher, oldest first so the order never jumps around. */
export function useCompanies(): Company[] | undefined {
  return useLiveQuery(() => db.companies.orderBy('createdAt').toArray(), [])
}

export function useActiveCompany(): Company | undefined {
  const activeCompanyId = useApp((s) => s.activeCompanyId)
  return useLiveQuery(
    async () => (activeCompanyId ? await db.companies.get(activeCompanyId) : undefined),
    [activeCompanyId],
  )
}

/**
 * Company-scoped reads. Passing no company id yields an empty list rather than
 * everything — data must never leak across companies.
 */
export function useClients(): Client[] | undefined {
  const companyId = useApp((s) => s.activeCompanyId)
  return useLiveQuery(async () => {
    if (!companyId) return []
    const clients = await db.clients.where('companyId').equals(companyId).toArray()
    return clients.sort((a, b) => a.name.localeCompare(b.name))
  }, [companyId])
}

export function useDocuments(kind?: 'invoice' | 'receipt'): Document[] | undefined {
  const companyId = useApp((s) => s.activeCompanyId)
  return useLiveQuery(async () => {
    if (!companyId) return []
    const all = await db.documents.where('companyId').equals(companyId).toArray()
    const filtered = kind ? all.filter((d) => d.kind === kind) : all
    // Newest first, then by number so same-day documents stay stable.
    return filtered.sort(
      (a, b) => b.issueDate.localeCompare(a.issueDate) || b.number.localeCompare(a.number),
    )
  }, [companyId, kind])
}

export function useExpenses(): Expense[] | undefined {
  const companyId = useApp((s) => s.activeCompanyId)
  return useLiveQuery(async () => {
    if (!companyId) return []
    const all = await db.expenses.where('companyId').equals(companyId).toArray()
    return all.sort((a, b) => b.date.localeCompare(a.date))
  }, [companyId])
}

export function useDocument(id?: string): Document | undefined | null {
  return useLiveQuery(async () => (id ? ((await db.documents.get(id)) ?? null) : null), [id])
}
