import { computeTotals, displayStatus, formatAmount, lineTotal } from './format'
import type { Company, Document, Expense } from '../types'

/** Statuses read better capitalised in a spreadsheet than as raw enum values. */
const statusLabel = (doc: Document): string => {
  const status = displayStatus(doc)
  return status.charAt(0).toUpperCase() + status.slice(1)
}

/**
 * A leading =, +, @ or control character makes a spreadsheet treat the cell as
 * a formula rather than text, which is how a client name becomes code on
 * someone else's machine. Prefixing with an apostrophe forces text.
 *
 * Numbers are left alone, so a negative figure like "-40.00" stays a number.
 */
function neutraliseFormula(text: string): string {
  if (!/^[=+@\t\r]/.test(text)) return text
  // A value that is genuinely numeric is not a formula risk.
  if (Number.isFinite(Number(text))) return text
  return `'${text}`
}

/** RFC-4180 quoting — Excel and Google Sheets both read this cleanly. */
function cell(value: unknown): string {
  if (value === null || value === undefined) return ''
  const text = neutraliseFormula(String(value))
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
}

export function toCsv(headers: string[], rows: unknown[][]): string {
  const lines = [headers.map(cell).join(','), ...rows.map((row) => row.map(cell).join(','))]
  // Leading BOM so Excel opens UTF-8 accents correctly.
  return `﻿${lines.join('\r\n')}\r\n`
}

const DOCUMENT_HEADERS = [
  'Number',
  'Type',
  'Status',
  'Issue Date',
  'Due Date',
  'Paid Date',
  'Client',
  'Client Email',
  'Currency',
  'Subtotal',
  'Discount',
  'Tax',
  'Total',
  'Payment Method',
  'Notes',
]

export function documentsToCsv(docs: Document[]): string {
  const rows = docs.map((doc) => {
    const totals = computeTotals(doc)
    return [
      doc.number,
      doc.kind === 'invoice' ? 'Invoice' : 'Receipt',
      statusLabel(doc),
      doc.issueDate,
      doc.dueDate ?? '',
      doc.paidDate ?? '',
      doc.client.name,
      doc.client.email ?? '',
      doc.currency,
      formatAmount(totals.subtotal),
      formatAmount(totals.discount),
      formatAmount(totals.tax),
      formatAmount(totals.total),
      doc.paymentMethod ?? '',
      doc.notes ?? '',
    ]
  })
  return toCsv(DOCUMENT_HEADERS, rows)
}

/** One row per line item — what a bookkeeper wants for revenue breakdowns. */
const LINE_ITEM_HEADERS = [
  'Number',
  'Type',
  'Status',
  'Issue Date',
  'Client',
  'Description',
  'Quantity',
  'Unit Price',
  'Tax Rate %',
  'Line Total',
  'Currency',
]

export function documentLinesToCsv(docs: Document[]): string {
  const rows = docs.flatMap((doc) =>
    doc.items.map((item) => [
      doc.number,
      doc.kind === 'invoice' ? 'Invoice' : 'Receipt',
      statusLabel(doc),
      doc.issueDate,
      doc.client.name,
      item.description,
      item.quantity,
      formatAmount(item.unitPrice),
      item.taxRate,
      formatAmount(lineTotal(item)),
      doc.currency,
    ]),
  )
  return toCsv(LINE_ITEM_HEADERS, rows)
}

const EXPENSE_HEADERS = [
  'Date',
  'Vendor',
  'Category',
  'Currency',
  'Net',
  'Tax',
  'Total',
  'Payment Method',
  'Source',
  'Has Scan',
  'Notes',
]

export function expensesToCsv(expenses: Expense[]): string {
  const rows = expenses.map((expense) => [
    expense.date,
    expense.vendor,
    expense.category,
    expense.currency,
    formatAmount(expense.total - expense.taxAmount),
    formatAmount(expense.taxAmount),
    formatAmount(expense.total),
    expense.paymentMethod ?? '',
    expense.source === 'scan' ? 'Scanned' : 'Manual',
    expense.attachmentId ? 'Yes' : 'No',
    expense.notes ?? '',
  ])
  return toCsv(EXPENSE_HEADERS, rows)
}

export function clientsToCsv(
  clients: { name: string; email?: string; phone?: string; addressLines: string[]; notes?: string }[],
): string {
  return toCsv(
    ['Name', 'Email', 'Phone', 'Address', 'Notes'],
    clients.map((c) => [c.name, c.email ?? '', c.phone ?? '', c.addressLines.join(', '), c.notes ?? '']),
  )
}

export const exportFilename = (company: Company, what: string, from: string, to: string): string =>
  `${company.name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${what}-${from}-to-${to}.csv`
