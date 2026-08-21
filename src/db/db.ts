import Dexie, { type Table } from 'dexie'
import {
  DEFAULT_EXPENSE_CATEGORIES,
  type Attachment,
  type Category,
  type Client,
  type Company,
  type Document,
  type Expense,
  type Setting,
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
  categories!: Table<Category, string>
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

    // v2 adds per-company expense categories and the recurring-invoice index.
    this.version(2)
      .stores({
        categories: 'id, companyId, name, [companyId+name]',
        documents:
          'id, companyId, kind, status, issueDate, number, seriesId, nextIssueDate, ' +
          '[companyId+kind], [companyId+status], [companyId+recurrence]',
      })
      .upgrade(async (tx) => {
        // Existing installs have companies but no category list yet. Seed each
        // one with the defaults so the pickers are never empty after upgrading.
        const companies = await tx.table('companies').toArray()
        const now = new Date().toISOString()
        const rows: Category[] = []
        for (const company of companies as Company[]) {
          DEFAULT_EXPENSE_CATEGORIES.forEach((name, index) => {
            rows.push({
              id: `${company.id}-cat-${index}`,
              companyId: company.id,
              name,
              sortOrder: index,
              createdAt: now,
            })
          })
        }
        if (rows.length) await tx.table('categories').bulkAdd(rows)
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
    [db.companies, db.clients, db.documents, db.expenses, db.attachments, db.categories],
    async () => {
      await db.clients.where('companyId').equals(companyId).delete()
      await db.documents.where('companyId').equals(companyId).delete()
      await db.expenses.where('companyId').equals(companyId).delete()
      await db.attachments.where('companyId').equals(companyId).delete()
      await db.categories.where('companyId').equals(companyId).delete()
      await db.companies.delete(companyId)
    },
  )
}

/** How many taken numbers to skip past before giving up and using the value. */
const MAX_NUMBER_PROBES = 10_000

/**
 * Claims the next document number for a company and bumps the counter in the
 * same transaction, so two quick clicks can never produce a duplicate.
 *
 * It also skips past any number already in use. The counter is user-editable in
 * Settings, and restoring a backup can reintroduce documents the counter has
 * already passed — either way, handing out a number twice would be a
 * bookkeeping problem, so the claim checks rather than trusting the counter.
 */
export async function claimNextNumber(
  companyId: string,
  kind: 'invoice' | 'receipt',
): Promise<string> {
  return db.transaction('rw', [db.companies, db.documents], async () => {
    const company = await db.companies.get(companyId)
    if (!company) throw new Error('Company not found')

    const isInvoice = kind === 'invoice'
    const prefix = isInvoice ? company.invoicePrefix : company.receiptPrefix

    // Every number this company has already used, so the scan below is one
    // read rather than one per candidate.
    const taken = new Set(
      (await db.documents.where('companyId').equals(companyId).toArray()).map((doc) => doc.number),
    )

    let candidate = isInvoice ? company.nextInvoiceNumber : company.nextReceiptNumber
    let number = `${prefix}${String(candidate).padStart(4, '0')}`
    let probes = 0
    while (taken.has(number) && probes < MAX_NUMBER_PROBES) {
      candidate += 1
      probes += 1
      number = `${prefix}${String(candidate).padStart(4, '0')}`
    }

    await db.companies.update(
      companyId,
      isInvoice ? { nextInvoiceNumber: candidate + 1 } : { nextReceiptNumber: candidate + 1 },
    )
    return number
  })
}

/** Gives a brand-new company the default expense category list. */
export async function seedCategories(companyId: string): Promise<void> {
  const existing = await db.categories.where('companyId').equals(companyId).count()
  if (existing > 0) return
  const now = new Date().toISOString()
  await db.categories.bulkPut(
    DEFAULT_EXPENSE_CATEGORIES.map((name, index) => ({
      id: `${companyId}-cat-${index}`,
      companyId,
      name,
      sortOrder: index,
      createdAt: now,
    })),
  )
}
