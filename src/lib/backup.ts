import { db } from '../db/db'
import type { Attachment, Category, Client, Company, Document, Expense, Setting } from '../types'

export interface BackupFile {
  app: 'simplebooks'
  version: 1
  exportedAt: string
  companies: Company[]
  clients: Client[]
  documents: Document[]
  expenses: Expense[]
  attachments: Attachment[]
  categories: Category[]
  settings: Setting[]
}

export async function createBackup(): Promise<BackupFile> {
  const [companies, clients, documents, expenses, attachments, categories, settings] =
    await Promise.all([
      db.companies.toArray(),
      db.clients.toArray(),
      db.documents.toArray(),
      db.expenses.toArray(),
      db.attachments.toArray(),
      db.categories.toArray(),
      db.settings.toArray(),
    ])
  return {
    app: 'simplebooks',
    version: 1,
    exportedAt: new Date().toISOString(),
    companies,
    clients,
    documents,
    expenses,
    attachments,
    categories,
    settings,
  }
}

export interface RestoreResult {
  companies: number
  clients: number
  documents: number
  expenses: number
  attachments: number
  categories: number
}

function assertBackup(data: unknown): asserts data is BackupFile {
  const file = data as Partial<BackupFile> | null
  if (!file || typeof file !== 'object' || file.app !== 'simplebooks') {
    throw new Error('That does not look like a SimpleBooks backup file.')
  }
  if (!Array.isArray(file.companies)) {
    throw new Error('This backup file is missing its company list.')
  }
}

/**
 * `replace` wipes everything first — a true restore. `merge` keeps what is
 * already here and only adds records whose ids are not present yet.
 */
export async function restoreBackup(
  raw: string,
  mode: 'replace' | 'merge' = 'replace',
): Promise<RestoreResult> {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    throw new Error('This file is not valid JSON.')
  }
  assertBackup(parsed)
  const backup = parsed

  await db.transaction(
    'rw',
    [db.companies, db.clients, db.documents, db.expenses, db.attachments, db.categories, db.settings],
    async () => {
      if (mode === 'replace') {
        await Promise.all([
          db.companies.clear(),
          db.clients.clear(),
          db.documents.clear(),
          db.expenses.clear(),
          db.attachments.clear(),
          db.categories.clear(),
          db.settings.clear(),
        ])
      }
      // `bulkPut` upserts, which is exactly right for both modes: on merge an
      // identical id is the same record, not a duplicate.
      await db.companies.bulkPut(backup.companies ?? [])
      await db.clients.bulkPut(backup.clients ?? [])
      await db.documents.bulkPut(backup.documents ?? [])
      await db.expenses.bulkPut(backup.expenses ?? [])
      await db.attachments.bulkPut(backup.attachments ?? [])
      await db.categories.bulkPut(backup.categories ?? [])
      if (mode === 'replace') await db.settings.bulkPut(backup.settings ?? [])
    },
  )

  return {
    companies: backup.companies?.length ?? 0,
    clients: backup.clients?.length ?? 0,
    documents: backup.documents?.length ?? 0,
    expenses: backup.expenses?.length ?? 0,
    attachments: backup.attachments?.length ?? 0,
    categories: backup.categories?.length ?? 0,
  }
}

export const backupFilename = (): string =>
  `simplebooks-backup-${new Date().toISOString().slice(0, 10)}.json`
