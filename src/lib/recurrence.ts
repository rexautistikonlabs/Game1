import { claimNextNumber, db, newId } from '../db/db'
import { addDays, today } from './format'
import type { Document, RecurrenceInterval } from '../types'

/**
 * Recurring invoices, kept deliberately dumb: no scheduler, no background
 * worker, no cron. One document per series carries the recurrence and the date
 * of the next copy; anything due is generated when the app is open, either by
 * the "Generate next" button or by the catch-up pass on startup.
 */

const MONTHS_PER_INTERVAL: Record<RecurrenceInterval, number> = {
  monthly: 1,
  quarterly: 3,
  yearly: 12,
}

/**
 * Adds whole months, clamping the day to the end of the target month so a
 * 31 January invoice recurs on 28/29 February rather than silently rolling into
 * March. Successive calls are computed from the anchor, not from the clamped
 * result, so a monthly series on the 31st stays on the 31st in months that have
 * one.
 */
export function addMonthsClamped(isoDate: string, months: number): string {
  const [year, month, day] = isoDate.split('-').map(Number) as [number, number, number]
  const targetMonthIndex = month - 1 + months
  const targetYear = year + Math.floor(targetMonthIndex / 12)
  const targetMonth = ((targetMonthIndex % 12) + 12) % 12
  // Day 0 of the following month is the last day of the target month.
  const daysInTargetMonth = new Date(Date.UTC(targetYear, targetMonth + 1, 0)).getUTCDate()
  const clampedDay = Math.min(day, daysInTargetMonth)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${targetYear}-${pad(targetMonth + 1)}-${pad(clampedDay)}`
}

/** The issue date that follows `isoDate` for the given cadence. */
export const nextOccurrence = (isoDate: string, interval: RecurrenceInterval): string =>
  addMonthsClamped(isoDate, MONTHS_PER_INTERVAL[interval])

/** True when a template has an occurrence ready to be created. */
export function isDue(doc: Document, asOf = today()): boolean {
  if (!doc.recurrence || !doc.nextIssueDate) return false
  if (doc.recurrenceEndDate && doc.nextIssueDate > doc.recurrenceEndDate) return false
  return doc.nextIssueDate <= asOf
}

/** How many of a company's series are waiting to be generated. */
export const dueTemplates = (docs: Document[], asOf = today()): Document[] =>
  docs.filter((doc) => isDue(doc, asOf))

/**
 * Creates the next invoice in a series and advances the template's
 * `nextIssueDate`.
 *
 * Runs inside one transaction that re-reads the template, so two clicks (or a
 * click racing the startup catch-up) cannot produce two invoices for the same
 * date. Returns the new document, or null if the template was no longer due by
 * the time the transaction ran.
 */
export async function generateNext(
  templateId: string,
  asOf = today(),
): Promise<Document | null> {
  return db.transaction('rw', [db.documents, db.companies], async () => {
    const template = await db.documents.get(templateId)
    if (!template || !template.recurrence || !template.nextIssueDate) return null
    // Re-check under the transaction: the state may have moved since we read it.
    if (!isDue(template, asOf)) return null

    const company = await db.companies.get(template.companyId)
    if (!company) return null

    const issueDate = template.nextIssueDate
    const number = await claimNextNumber(template.companyId, 'invoice')
    const now = new Date().toISOString()
    const seriesId = template.seriesId ?? template.id

    const generated: Document = {
      ...structuredClone(template),
      id: newId(),
      number,
      status: 'draft',
      issueDate,
      dueDate: addDays(issueDate, company.paymentTermsDays),
      paidDate: undefined,
      items: template.items.map((item) => ({ ...item, id: newId() })),
      // The copy is a member of the series, never a second template.
      recurrence: undefined,
      nextIssueDate: undefined,
      recurrenceEndDate: undefined,
      seriesId,
      createdAt: now,
      updatedAt: now,
    }

    const advanced = nextOccurrence(issueDate, template.recurrence)
    await db.documents.bulkPut([
      generated,
      { ...template, seriesId, nextIssueDate: advanced, updatedAt: now },
    ])
    return generated
  })
}

/**
 * Generates every occurrence that has come due, across every company.
 *
 * `maxPerSeries` stops a series that has been dormant for years from producing
 * hundreds of drafts the first time the app is reopened; whatever is left stays
 * due and appears on the next pass.
 */
export async function generateAllDue(
  asOf = today(),
  maxPerSeries = 12,
): Promise<Document[]> {
  const templates = await db.documents.filter((doc) => Boolean(doc.recurrence)).toArray()
  const created: Document[] = []

  for (const template of templates) {
    for (let round = 0; round < maxPerSeries; round += 1) {
      const generated = await generateNext(template.id, asOf)
      if (!generated) break
      created.push(generated)
    }
  }
  return created
}

/** Shared in-flight promise: StrictMode mounts effects twice in development. */
let catchUpPromise: Promise<Document[]> | null = null

/** Runs the catch-up pass once, however many callers ask for it. */
export function catchUpRecurring(asOf = today()): Promise<Document[]> {
  catchUpPromise ??= generateAllDue(asOf).finally(() => {
    catchUpPromise = null
  })
  return catchUpPromise
}

/** Every document in the same series, oldest first. */
export async function seriesMembers(doc: Document): Promise<Document[]> {
  const seriesId = doc.seriesId ?? doc.id
  const members = await db.documents.where('seriesId').equals(seriesId).toArray()
  // The template predates its own seriesId when recurrence was just switched on.
  if (!members.some((member) => member.id === doc.id)) members.push(doc)
  return members.sort((a, b) => a.issueDate.localeCompare(b.issueDate))
}
