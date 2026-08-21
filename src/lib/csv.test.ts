import { describe, expect, it } from 'vitest'
import { documentsToCsv, expensesToCsv, toCsv } from './csv'
import type { Document, Expense } from '../types'

describe('toCsv quoting', () => {
  it('quotes cells containing a comma, a quote or a newline', () => {
    const csv = toCsv(['A', 'B'], [['plain', 'has, comma'], ['say "hi"', 'two\nlines']])
    expect(csv).toContain('"has, comma"')
    expect(csv).toContain('"say ""hi"""')
    expect(csv).toContain('"two\nlines"')
  })

  it('starts with a BOM so Excel reads UTF-8 accents', () => {
    expect(toCsv(['Name'], [['Bürobedarf']]).charCodeAt(0)).toBe(0xfeff)
  })

  it('uses CRLF line endings', () => {
    expect(toCsv(['A'], [['1'], ['2']])).toBe('﻿A\r\n1\r\n2\r\n')
  })
})

describe('CSV formula injection', () => {
  it('neutralises a cell that a spreadsheet would execute', () => {
    // The classic payload: a name that becomes a command in Excel.
    const csv = toCsv(['Name'], [['=cmd|\' /C calc\'!A0']])
    expect(csv).toContain("'=cmd")
    expect(csv).not.toMatch(/(^|\r\n)=cmd/)
  })

  it('covers +, @ and tab as well as =', () => {
    expect(toCsv(['A'], [['+1+1']])).toContain("'+1+1")
    expect(toCsv(['A'], [['@SUM(A1:A9)']])).toContain("'@SUM")
    expect(toCsv(['A'], [['\tsneaky']])).toContain("'\t")
  })

  it('leaves a genuine negative number alone', () => {
    // Prefixing this would turn a number into text in the spreadsheet.
    expect(toCsv(['Net'], [['-40.00']])).toContain('-40.00')
    expect(toCsv(['Net'], [['-40.00']])).not.toContain("'-40.00")
  })

  it('leaves ordinary text alone', () => {
    expect(toCsv(['A'], [['Harbor & Finch']])).toContain('Harbor & Finch')
  })
})

const doc = (over: Partial<Document>): Document =>
  ({
    id: 'd',
    companyId: 'c',
    kind: 'invoice',
    number: 'INV-0001',
    status: 'sent',
    client: { name: 'Acme', addressLines: [] },
    issueDate: '2026-03-01',
    dueDate: '2026-03-31',
    items: [{ id: '1', description: 'Work', quantity: 2, unitPrice: 100, taxRate: 10 }],
    discount: 0,
    currency: 'USD',
    createdAt: '',
    updatedAt: '',
    ...over,
  }) as Document

describe('documentsToCsv', () => {
  it('writes computed totals, not stored ones', () => {
    const csv = documentsToCsv([doc({})])
    const row = csv.split('\r\n')[1]!
    // subtotal 200, tax 20, total 220
    expect(row).toContain('200.00')
    expect(row).toContain('20.00')
    expect(row).toContain('220.00')
  })

  it('capitalises the status and reports the derived Overdue state', () => {
    const csv = documentsToCsv([doc({ status: 'sent', dueDate: '2020-01-01' })])
    expect(csv).toContain('Overdue')
  })

  it('writes Paid for a settled invoice', () => {
    expect(documentsToCsv([doc({ status: 'paid', paidDate: '2026-03-05' })])).toContain('Paid')
  })
})

describe('expensesToCsv', () => {
  it('splits the gross amount into net and tax', () => {
    const expense = {
      id: 'e',
      companyId: 'c',
      vendor: 'Shop',
      date: '2026-03-01',
      total: 108,
      taxAmount: 8,
      category: 'Office Supplies',
      currency: 'USD',
      source: 'manual',
      createdAt: '',
      updatedAt: '',
    } as Expense
    const row = expensesToCsv([expense]).split('\r\n')[1]!
    expect(row).toContain('100.00')
    expect(row).toContain('8.00')
    expect(row).toContain('108.00')
  })
})
