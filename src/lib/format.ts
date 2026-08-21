import type { Document, DocumentTotals, LineItem } from '../types'

const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100

export function formatMoney(amount: number, currency = 'USD'): string {
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(amount || 0)
  } catch {
    // Unknown currency code — still show something sensible.
    return `${currency} ${(amount || 0).toFixed(2)}`
  }
}

/** Bare number, no symbol — used in CSV exports. */
export const formatAmount = (amount: number): string => (amount || 0).toFixed(2)

export function currencySymbol(currency = 'USD'): string {
  try {
    const parts = new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency,
    }).formatToParts(0)
    return parts.find((p) => p.type === 'currency')?.value ?? currency
  } catch {
    return currency
  }
}

export const today = (): string => new Date().toISOString().slice(0, 10)

export function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00`)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

export function formatDate(iso?: string): string {
  if (!iso) return '—'
  const d = new Date(`${iso}T00:00:00`)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
}

export function formatDateLong(iso?: string): string {
  if (!iso) return '—'
  const d = new Date(`${iso}T00:00:00`)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })
}

export function monthLabel(iso: string): string {
  const d = new Date(`${iso}T00:00:00`)
  return d.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })
}

export const monthStart = (d = new Date()): string =>
  new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)

export const monthEnd = (d = new Date()): string =>
  new Date(d.getFullYear(), d.getMonth() + 1, 0).toISOString().slice(0, 10)

export const yearStart = (d = new Date()): string =>
  new Date(d.getFullYear(), 0, 1).toISOString().slice(0, 10)

export const lineTotal = (item: LineItem): number =>
  round2((Number(item.quantity) || 0) * (Number(item.unitPrice) || 0))

/**
 * All money on a document is derived from its line items — nothing is stored,
 * so a document can never disagree with itself.
 * A flat discount is spread across lines proportionally before tax.
 */
export function computeTotals(doc: Pick<Document, 'items' | 'discount'>): DocumentTotals {
  const subtotal = round2(doc.items.reduce((sum, item) => sum + lineTotal(item), 0))
  const discount = round2(Math.min(Math.max(Number(doc.discount) || 0, 0), subtotal))
  const ratio = subtotal > 0 ? (subtotal - discount) / subtotal : 0

  const tax = round2(
    doc.items.reduce(
      (sum, item) => sum + lineTotal(item) * ratio * ((Number(item.taxRate) || 0) / 100),
      0,
    ),
  )

  const taxableBase = round2(subtotal - discount)
  return { subtotal, discount, taxableBase, tax, total: round2(taxableBase + tax) }
}

/** The tax rates actually in use, so the preview can label "Tax (8.5%)". */
export function taxRateSummary(items: LineItem[]): string {
  const rates = [...new Set(items.filter((i) => i.taxRate > 0).map((i) => i.taxRate))]
  if (rates.length === 0) return ''
  if (rates.length === 1) return `${rates[0]}%`
  return 'mixed'
}

/** Overdue is never stored — it is just an unpaid invoice past its due date. */
export function isOverdue(doc: Document, asOf = today()): boolean {
  return (
    doc.kind === 'invoice' &&
    doc.status !== 'paid' &&
    doc.status !== 'draft' &&
    !!doc.dueDate &&
    doc.dueDate < asOf
  )
}

export type DisplayStatus = 'draft' | 'sent' | 'paid' | 'overdue'

export const displayStatus = (doc: Document): DisplayStatus =>
  isOverdue(doc) ? 'overdue' : doc.status

export function daysOverdue(doc: Document): number {
  if (!isOverdue(doc) || !doc.dueDate) return 0
  const ms = new Date(`${today()}T00:00:00`).getTime() - new Date(`${doc.dueDate}T00:00:00`).getTime()
  return Math.max(0, Math.round(ms / 86_400_000))
}

export function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join('')
}

/** Readable contrast colour for text sitting on a brand-coloured background. */
export function readableOn(hex: string): string {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim())
  if (!m) return '#ffffff'
  const int = parseInt(m[1]!, 16)
  const [r, g, b] = [(int >> 16) & 255, (int >> 8) & 255, int & 255]
  // Relative luminance (sRGB, gamma-corrected).
  const channel = (c: number) => {
    const s = c / 255
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  }
  const luminance = 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
  return luminance > 0.45 ? '#15181c' : '#ffffff'
}

/** Same hue, low alpha — for soft brand-tinted backgrounds. */
export function withAlpha(hex: string, alpha: number): string {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim())
  if (!m) return `rgba(29, 78, 216, ${alpha})`
  const int = parseInt(m[1]!, 16)
  return `rgba(${(int >> 16) & 255}, ${(int >> 8) & 255}, ${int & 255}, ${alpha})`
}
