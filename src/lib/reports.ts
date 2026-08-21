import { computeTotals, isOverdue, monthStart, today } from './format'
import { toCsv } from './csv'
import type { Document, Expense } from '../types'

/**
 * Report figures, computed from the same documents the rest of the app reads.
 * Nothing here is stored: a report is a view over the ledger, so it can never
 * drift from it.
 */

export interface DateRange {
  from: string
  to: string
}

export interface MonthRow {
  /** `YYYY-MM`. */
  month: string
  income: number
  expenses: number
  net: number
}

export interface CategoryRow {
  name: string
  total: number
  count: number
}

export interface ClientRow {
  name: string
  total: number
  count: number
}

export interface ReportSummary {
  range: DateRange
  /** Money actually received in the range — paid documents only. */
  income: number
  /** Money spent in the range. */
  expenses: number
  net: number
  /** Total billed in the range, whether paid or not. */
  invoiced: number
  /** Unpaid, non-draft invoices as of now. Not limited to the range: what you
   *  are owed is a present-tense fact, not a historical one. */
  outstanding: number
  outstandingCount: number
  overdue: number
  overdueCount: number
  /** Tax charged on documents issued in the range. */
  taxCollected: number
  /** Tax paid on expenses in the range. */
  taxPaid: number
  paidCount: number
  expenseCount: number
  months: MonthRow[]
  categories: CategoryRow[]
  clients: ClientRow[]
}

const inRange = (date: string, range: DateRange): boolean =>
  date >= range.from && date <= range.to

const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100

/**
 * A paid document counts as income on the day it was paid, not the day it was
 * issued — that is what makes "revenue this month" mean money that arrived.
 * Documents with no recorded payment date fall back to the issue date.
 */
export const incomeDate = (doc: Document): string => doc.paidDate ?? doc.issueDate

export function buildReport(
  documents: Document[],
  expenses: Expense[],
  range: DateRange,
): ReportSummary {
  const paid = documents.filter((doc) => doc.status === 'paid' && inRange(incomeDate(doc), range))
  const issued = documents.filter((doc) => inRange(doc.issueDate, range))
  const spent = expenses.filter((expense) => inRange(expense.date, range))

  const income = round2(paid.reduce((sum, doc) => sum + computeTotals(doc).total, 0))
  const expenseTotal = round2(spent.reduce((sum, expense) => sum + expense.total, 0))

  // Outstanding is deliberately as-of-now rather than range-bound.
  const unpaid = documents.filter((doc) => doc.kind === 'invoice' && doc.status === 'sent')
  const overdueDocs = unpaid.filter((doc) => isOverdue(doc))

  // --- Month-by-month income against expenses.
  const buckets = new Map<string, MonthRow>()
  const bucket = (month: string): MonthRow => {
    let row = buckets.get(month)
    if (!row) {
      row = { month, income: 0, expenses: 0, net: 0 }
      buckets.set(month, row)
    }
    return row
  }
  for (const doc of paid) bucket(incomeDate(doc).slice(0, 7)).income += computeTotals(doc).total
  for (const expense of spent) bucket(expense.date.slice(0, 7)).expenses += expense.total

  const months = [...buckets.values()]
    .map((row) => ({
      month: row.month,
      income: round2(row.income),
      expenses: round2(row.expenses),
      net: round2(row.income - row.expenses),
    }))
    .sort((a, b) => a.month.localeCompare(b.month))

  // --- Expenses grouped by category, biggest first.
  const byCategory = new Map<string, CategoryRow>()
  for (const expense of spent) {
    const name = expense.category || 'Uncategorised'
    const row = byCategory.get(name) ?? { name, total: 0, count: 0 }
    row.total += expense.total
    row.count += 1
    byCategory.set(name, row)
  }
  const categories = [...byCategory.values()]
    .map((row) => ({ ...row, total: round2(row.total) }))
    .sort((a, b) => b.total - a.total)

  // --- Income grouped by client. Keyed on the snapshot name, so a client
  // deleted from the picklist still shows up in past reports.
  const byClient = new Map<string, ClientRow>()
  for (const doc of paid) {
    const name = doc.client.name || 'Unnamed'
    const row = byClient.get(name) ?? { name, total: 0, count: 0 }
    row.total += computeTotals(doc).total
    row.count += 1
    byClient.set(name, row)
  }
  const clients = [...byClient.values()]
    .map((row) => ({ ...row, total: round2(row.total) }))
    .sort((a, b) => b.total - a.total)

  return {
    range,
    income,
    expenses: expenseTotal,
    net: round2(income - expenseTotal),
    invoiced: round2(
      issued
        .filter((doc) => doc.kind === 'invoice')
        .reduce((sum, doc) => sum + computeTotals(doc).total, 0),
    ),
    outstanding: round2(unpaid.reduce((sum, doc) => sum + computeTotals(doc).total, 0)),
    outstandingCount: unpaid.length,
    overdue: round2(overdueDocs.reduce((sum, doc) => sum + computeTotals(doc).total, 0)),
    overdueCount: overdueDocs.length,
    taxCollected: round2(issued.reduce((sum, doc) => sum + computeTotals(doc).tax, 0)),
    taxPaid: round2(spent.reduce((sum, expense) => sum + expense.taxAmount, 0)),
    paidCount: paid.length,
    expenseCount: spent.length,
    months,
    categories,
    clients,
  }
}

/** Named date ranges, so the common cases are one click. */
export type RangePreset =
  | 'this-month'
  | 'last-month'
  | 'this-quarter'
  | 'this-year'
  | 'last-year'
  | 'all'
  | 'custom'

export const RANGE_PRESET_LABELS: Record<RangePreset, string> = {
  'this-month': 'This month',
  'last-month': 'Last month',
  'this-quarter': 'This quarter',
  'this-year': 'This year',
  'last-year': 'Last year',
  all: 'All time',
  custom: 'Custom range',
}

const pad = (n: number) => String(n).padStart(2, '0')
const iso = (year: number, month: number, day: number) => `${year}-${pad(month)}-${pad(day)}`
const lastDayOf = (year: number, month: number) => new Date(Date.UTC(year, month, 0)).getUTCDate()

export function presetRange(preset: RangePreset, asOf = today()): DateRange {
  const [year, month] = asOf.split('-').map(Number) as [number, number]

  switch (preset) {
    case 'this-month':
      return { from: iso(year, month, 1), to: iso(year, month, lastDayOf(year, month)) }
    case 'last-month': {
      const y = month === 1 ? year - 1 : year
      const m = month === 1 ? 12 : month - 1
      return { from: iso(y, m, 1), to: iso(y, m, lastDayOf(y, m)) }
    }
    case 'this-quarter': {
      const firstMonth = Math.floor((month - 1) / 3) * 3 + 1
      const lastMonth = firstMonth + 2
      return {
        from: iso(year, firstMonth, 1),
        to: iso(year, lastMonth, lastDayOf(year, lastMonth)),
      }
    }
    case 'this-year':
      return { from: iso(year, 1, 1), to: iso(year, 12, 31) }
    case 'last-year':
      return { from: iso(year - 1, 1, 1), to: iso(year - 1, 12, 31) }
    case 'all':
      return { from: '0000-01-01', to: '9999-12-31' }
    case 'custom':
      return { from: monthStart(), to: asOf }
  }
}

/** The whole report as one CSV: summary, then each breakdown as its own block. */
export function reportToCsv(report: ReportSummary, companyName: string, currency: string): string {
  const money = (n: number) => n.toFixed(2)
  const rangeLabel =
    report.range.from === '0000-01-01' ? 'All time' : `${report.range.from} to ${report.range.to}`

  const rows: unknown[][] = [
    ['Company', companyName],
    ['Date range', rangeLabel],
    ['Currency', currency],
    [],
    ['Summary', 'Amount', 'Count'],
    ['Income received', money(report.income), report.paidCount],
    ['Expenses', money(report.expenses), report.expenseCount],
    ['Net', money(report.net), ''],
    ['Invoiced in range', money(report.invoiced), ''],
    ['Outstanding (as of today)', money(report.outstanding), report.outstandingCount],
    ['Overdue (as of today)', money(report.overdue), report.overdueCount],
    ['Tax collected', money(report.taxCollected), ''],
    ['Tax paid on expenses', money(report.taxPaid), ''],
    [],
    ['Month', 'Income', 'Expenses', 'Net'],
    ...report.months.map((row) => [row.month, money(row.income), money(row.expenses), money(row.net)]),
    [],
    ['Expense category', 'Total', 'Count'],
    ...report.categories.map((row) => [row.name, money(row.total), row.count]),
    [],
    ['Client', 'Income received', 'Documents'],
    ...report.clients.map((row) => [row.name, money(row.total), row.count]),
  ]

  // The header is part of the body here, so pass an empty header row.
  return toCsv(['SimpleBooks report'], rows)
}
