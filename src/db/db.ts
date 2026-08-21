import Dexie, { type Table } from 'dexie'
import type {
  Attachment,
  Client,
  Company,
  Document,
  Expense,
  Setting,
} from '../types'

/**
 * The entire database. Everything is local — IndexedDB in the browser, or the
 * same IndexedDB inside Electron's Chromium. There is no server, ever.
 */
export class SimpleBooksDB extends Dexie {
  companies!: Table<Company, string>
  clients!: Table<Client, string>
  documents!: Table<Document, string>
  expenses!: Table<Expense, string>
  attachments!: Table<Attachment, string>
  settings!: Table<Setting, string>

  constructor() {
    super('simplebooks')
    this.version(1).stores({
      companies: 'id, name, createdAt',
      clients: 'id, companyId, name, [companyId+name]',
      documents: 'id, companyId, kind, status, issueDate, number, [companyId+kind], [companyId+status]',
      expenses: 'id, companyId, date, category, vendor, [companyId+date]',
      attachments: 'id, companyId',
      settings: 'key',
    })
  }
}

export const db = new SimpleBooksDB()

export const newId = (): string =>
  globalThis.crypto?.randomUUID?.() ??
  `id-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`

/** Small key/value bag for app-level (not company-level) preferences. */
export async function getSetting<T>(key: string, fallback: T): Promise<T> {
  const row = await db.settings.get(key)
  return row === undefined ? fallback : (row.value as T)
}

export async function setSetting(key: string, value: unknown): Promise<void> {
  await db.settings.put({ key, value })
}

/** Deleting a company takes every record that belongs to it with it. */
export async function deleteCompanyCascade(companyId: string): Promise<void> {
  await db.transaction(
    'rw',
    [db.companies, db.clients, db.documents, db.expenses, db.attachments],
    async () => {
      await db.clients.where('companyId').equals(companyId).delete()
      await db.documents.where('companyId').equals(companyId).delete()
      await db.expenses.where('companyId').equals(companyId).delete()
      await db.attachments.where('companyId').equals(companyId).delete()
      await db.companies.delete(companyId)
    },
  )
}

/**
 * Claims the next document number for a company and bumps the counter in the
 * same transaction, so two quick clicks can never produce a duplicate.
 */
export async function claimNextNumber(
  companyId: string,
  kind: 'invoice' | 'receipt',
): Promise<string> {
  return db.transaction('rw', db.companies, async () => {
    const company = await db.companies.get(companyId)
    if (!company) throw new Error('Company not found')

    const isInvoice = kind === 'invoice'
    const next = isInvoice ? company.nextInvoiceNumber : company.nextReceiptNumber
    const prefix = isInvoice ? company.invoicePrefix : company.receiptPrefix

    await db.companies.update(companyId,
      isInvoice ? { nextInvoiceNumber: next + 1 } : { nextReceiptNumber: next + 1 },
    )
    return `${prefix}${String(next).padStart(4, '0')}`
  })
}
