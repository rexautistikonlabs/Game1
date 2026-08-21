import { describe, expect, it } from 'vitest'
import { buildReport, presetRange, type DateRange } from './reports'
import type { Document, Expense } from '../types'

const invoice = (over: Partial<Document>): Document =>
  ({
    id: Math.random().toString(36).slice(2),
    companyId: 'c',
    kind: 'invoice',
    number: 'INV',
    status: 'sent',
    client: { name: 'Acme', addressLines: [] },
    issueDate: '2026-03-01',
    items: [{ id: '1', description: 'Work', quantity: 1, unitPrice: 100, taxRate: 0 }],
    discount: 0,
    currency: 'USD',
    createdAt: '',
    updatedAt: '',
    ...over,
  }) as Document

const expense = (over: Partial<Expense>): Expense =>
  ({
    id: Math.random().toString(36).slice(2),
    companyId: 'c',
    vendor: 'Shop',
    date: '2026-03-05',
    total: 50,
    taxAmount: 0,
    category: 'Office Supplies',
    currency: 'USD',
    source: 'manual',
    createdAt: '',
    updatedAt: '',
    ...over,
  }) as Expense

const MARCH: DateRange = { from: '2026-03-01', to: '2026-03-31' }

describe('buildReport income', () => {
  it('counts a paid document on the day it was paid, not issued', () => {
    const docs = [invoice({ status: 'paid', issueDate: '2026-02-20', paidDate: '2026-03-03' })]
    expect(buildReport(docs, [], MARCH).income).toBe(100)
    expect(buildReport(docs, [], { from: '2026-02-01', to: '2026-02-28' }).income).toBe(0)
  })

  it('falls back to the issue date when no payment date was recorded', () => {
    const docs = [invoice({ status: 'paid', issueDate: '2026-03-10', paidDate: undefined })]
    expect(buildReport(docs, [], MARCH).income).toBe(100)
  })

  it('ignores unpaid and draft documents', () => {
    const docs = [
      invoice({ status: 'sent', issueDate: '2026-03-02' }),
      invoice({ status: 'draft', issueDate: '2026-03-02' }),
    ]
    expect(buildReport(docs, [], MARCH).income).toBe(0)
  })

  it('includes receipts as income', () => {
    const docs = [invoice({ kind: 'receipt', status: 'paid', paidDate: '2026-03-04' })]
    expect(buildReport(docs, [], MARCH).income).toBe(100)
  })

  it('includes tax in the money received', () => {
    const docs = [
      invoice({
        status: 'paid',
        paidDate: '2026-03-04',
        items: [{ id: '1', description: 'Work', quantity: 1, unitPrice: 100, taxRate: 10 }],
      }),
    ]
    expect(buildReport(docs, [], MARCH).income).toBe(110)
  })
})

describe('buildReport outstanding', () => {
  it('reports what is owed as of now, regardless of the range', () => {
    // Issued long before the range, still unpaid: you are still owed it.
    const docs = [invoice({ status: 'sent', issueDate: '2020-01-01', dueDate: '2020-02-01' })]
    const report = buildReport(docs, [], MARCH)
    expect(report.outstanding).toBe(100)
    expect(report.outstandingCount).toBe(1)
    expect(report.overdue).toBe(100)
  })

  it('does not count drafts or receipts as outstanding', () => {
    const docs = [
      invoice({ status: 'draft' }),
      invoice({ kind: 'receipt', status: 'sent' }),
    ]
    expect(buildReport(docs, [], MARCH).outstanding).toBe(0)
  })
})

describe('buildReport expenses and net', () => {
  it('sums expenses in the range and nets them off', () => {
    const docs = [invoice({ status: 'paid', paidDate: '2026-03-02' })]
    const spend = [expense({ total: 30 }), expense({ total: 20, date: '2026-04-01' })]
    const report = buildReport(docs, spend, MARCH)
    expect(report.expenses).toBe(30)
    expect(report.net).toBe(70)
  })

  it('reports a negative net when spending exceeds income', () => {
    expect(buildReport([], [expense({ total: 40 })], MARCH).net).toBe(-40)
  })

  it('separates tax collected from tax paid', () => {
    const docs = [
      invoice({
        issueDate: '2026-03-02',
        items: [{ id: '1', description: 'W', quantity: 1, unitPrice: 200, taxRate: 10 }],
      }),
    ]
    const report = buildReport(docs, [expense({ total: 50, taxAmount: 4 })], MARCH)
    expect(report.taxCollected).toBe(20)
    expect(report.taxPaid).toBe(4)
  })
})

describe('buildReport breakdowns', () => {
  it('buckets by month, in order', () => {
    const docs = [
      invoice({ status: 'paid', paidDate: '2026-01-10' }),
      invoice({ status: 'paid', paidDate: '2026-03-10' }),
    ]
    const report = buildReport(docs, [expense({ date: '2026-02-10', total: 25 })], {
      from: '2026-01-01',
      to: '2026-12-31',
    })
    expect(report.months.map((m) => m.month)).toEqual(['2026-01', '2026-02', '2026-03'])
    expect(report.months[1]).toMatchObject({ income: 0, expenses: 25, net: -25 })
  })

  it('groups expenses by category, largest first', () => {
    const spend = [
      expense({ category: 'Travel', total: 10 }),
      expense({ category: 'Travel', total: 40 }),
      expense({ category: 'Meals', total: 30 }),
    ]
    const report = buildReport([], spend, MARCH)
    expect(report.categories).toEqual([
      { name: 'Travel', total: 50, count: 2 },
      { name: 'Meals', total: 30, count: 1 },
    ])
  })

  it('labels an expense with no category rather than dropping it', () => {
    const report = buildReport([], [expense({ category: '' })], MARCH)
    expect(report.categories[0]?.name).toBe('Uncategorised')
  })

  it('groups income by client, largest first', () => {
    const docs = [
      invoice({ status: 'paid', paidDate: '2026-03-01', client: { name: 'Acme', addressLines: [] } }),
      invoice({
        status: 'paid',
        paidDate: '2026-03-02',
        client: { name: 'Globex', addressLines: [] },
        items: [{ id: '1', description: 'W', quantity: 1, unitPrice: 500, taxRate: 0 }],
      }),
    ]
    const report = buildReport(docs, [], MARCH)
    expect(report.clients.map((c) => c.name)).toEqual(['Globex', 'Acme'])
  })
})

describe('presetRange', () => {
  it('covers the whole calendar month', () => {
    expect(presetRange('this-month', '2026-03-14')).toEqual({ from: '2026-03-01', to: '2026-03-31' })
    expect(presetRange('this-month', '2026-02-14')).toEqual({ from: '2026-02-01', to: '2026-02-28' })
    expect(presetRange('this-month', '2028-02-14')).toEqual({ from: '2028-02-01', to: '2028-02-29' })
  })

  it('rolls back across the year boundary for last month', () => {
    expect(presetRange('last-month', '2026-01-09')).toEqual({ from: '2025-12-01', to: '2025-12-31' })
    expect(presetRange('last-month', '2026-03-09')).toEqual({ from: '2026-02-01', to: '2026-02-28' })
  })

  it('snaps quarters to calendar quarters', () => {
    expect(presetRange('this-quarter', '2026-01-05')).toEqual({ from: '2026-01-01', to: '2026-03-31' })
    expect(presetRange('this-quarter', '2026-05-05')).toEqual({ from: '2026-04-01', to: '2026-06-30' })
    expect(presetRange('this-quarter', '2026-08-21')).toEqual({ from: '2026-07-01', to: '2026-09-30' })
    expect(presetRange('this-quarter', '2026-12-31')).toEqual({ from: '2026-10-01', to: '2026-12-31' })
  })

  it('handles years', () => {
    expect(presetRange('this-year', '2026-08-21')).toEqual({ from: '2026-01-01', to: '2026-12-31' })
    expect(presetRange('last-year', '2026-08-21')).toEqual({ from: '2025-01-01', to: '2025-12-31' })
  })
})
