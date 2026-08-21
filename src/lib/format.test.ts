import { describe, expect, it } from 'vitest'
import { computeTotals, isOverdue, readableOn, taxRateSummary } from './format'
import type { Document, LineItem } from '../types'

const item = (quantity: number, unitPrice: number, taxRate = 0): LineItem => ({
  id: Math.random().toString(36).slice(2),
  description: 'Work',
  quantity,
  unitPrice,
  taxRate,
})

describe('computeTotals', () => {
  it('adds up the line items', () => {
    expect(computeTotals({ items: [item(4, 250), item(1, 80)], discount: 0 })).toMatchObject({
      subtotal: 1080,
      tax: 0,
      total: 1080,
    })
  })

  it('taxes each line at its own rate', () => {
    const totals = computeTotals({ items: [item(1, 100, 10), item(1, 100, 20)], discount: 0 })
    expect(totals.tax).toBe(30)
    expect(totals.total).toBe(230)
  })

  it('applies a flat discount before tax, spread across the lines', () => {
    // 200 subtotal, 20 off → 180 taxable at 10% → 18 tax.
    const totals = computeTotals({ items: [item(1, 100, 10), item(1, 100, 10)], discount: 20 })
    expect(totals.taxableBase).toBe(180)
    expect(totals.tax).toBe(18)
    expect(totals.total).toBe(198)
  })

  it('never lets a discount exceed the subtotal', () => {
    const totals = computeTotals({ items: [item(1, 50)], discount: 500 })
    expect(totals.discount).toBe(50)
    expect(totals.total).toBe(0)
  })

  it('rounds to cents rather than accumulating float error', () => {
    expect(computeTotals({ items: [item(3, 0.1)], discount: 0 }).subtotal).toBe(0.3)
  })
})

describe('taxRateSummary', () => {
  it('names a single rate, and says "mixed" for more than one', () => {
    expect(taxRateSummary([item(1, 10, 8.5)])).toBe('8.5%')
    expect(taxRateSummary([item(1, 10, 8.5), item(1, 10, 20)])).toBe('mixed')
    expect(taxRateSummary([item(1, 10, 0)])).toBe('')
  })
})

describe('isOverdue', () => {
  const invoice = (over: Partial<Document>): Document =>
    ({
      id: 'i',
      companyId: 'c',
      kind: 'invoice',
      number: 'INV-1',
      status: 'sent',
      client: { name: 'A', addressLines: [] },
      issueDate: '2026-01-01',
      dueDate: '2026-02-01',
      items: [],
      discount: 0,
      currency: 'USD',
      createdAt: '',
      updatedAt: '',
      ...over,
    }) as Document

  it('flags a sent invoice past its due date', () => {
    expect(isOverdue(invoice({}), '2026-03-01')).toBe(true)
  })

  it('never flags a draft, a paid invoice, or a receipt', () => {
    expect(isOverdue(invoice({ status: 'draft' }), '2026-03-01')).toBe(false)
    expect(isOverdue(invoice({ status: 'paid' }), '2026-03-01')).toBe(false)
    expect(isOverdue(invoice({ kind: 'receipt' }), '2026-03-01')).toBe(false)
  })

  it('is not overdue on the due date itself', () => {
    expect(isOverdue(invoice({}), '2026-02-01')).toBe(false)
  })
})

describe('readableOn', () => {
  it('picks dark text on light brand colours and light text on dark ones', () => {
    expect(readableOn('#f4d03f')).toBe('#15181c')
    expect(readableOn('#1d4ed8')).toBe('#ffffff')
  })
})
