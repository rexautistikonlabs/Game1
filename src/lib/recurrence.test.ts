import { describe, expect, it } from 'vitest'
import { addMonthsClamped, isDue, nextOccurrence } from './recurrence'
import type { Document } from '../types'

describe('addMonthsClamped', () => {
  it('adds whole months', () => {
    expect(addMonthsClamped('2026-03-14', 1)).toBe('2026-04-14')
    expect(addMonthsClamped('2026-03-14', 3)).toBe('2026-06-14')
    expect(addMonthsClamped('2026-03-14', 12)).toBe('2027-03-14')
  })

  it('rolls the year over correctly', () => {
    expect(addMonthsClamped('2026-11-30', 1)).toBe('2026-12-30')
    expect(addMonthsClamped('2026-12-15', 1)).toBe('2027-01-15')
    expect(addMonthsClamped('2026-10-31', 3)).toBe('2027-01-31')
  })

  it('clamps to the end of a shorter month instead of overflowing', () => {
    // The classic bug: naive date maths turns 31 Jan + 1 month into 3 March.
    expect(addMonthsClamped('2026-01-31', 1)).toBe('2026-02-28')
    expect(addMonthsClamped('2026-03-31', 1)).toBe('2026-04-30')
    expect(addMonthsClamped('2026-05-31', 1)).toBe('2026-06-30')
  })

  it('handles leap years', () => {
    expect(addMonthsClamped('2028-01-31', 1)).toBe('2028-02-29')
    expect(addMonthsClamped('2028-02-29', 12)).toBe('2029-02-28')
  })
})

describe('nextOccurrence', () => {
  it('maps each interval to the right number of months', () => {
    expect(nextOccurrence('2026-01-15', 'monthly')).toBe('2026-02-15')
    expect(nextOccurrence('2026-01-15', 'quarterly')).toBe('2026-04-15')
    expect(nextOccurrence('2026-01-15', 'yearly')).toBe('2027-01-15')
  })
})

const template = (over: Partial<Document>): Document =>
  ({
    id: 't',
    companyId: 'c',
    kind: 'invoice',
    number: 'INV-1',
    status: 'sent',
    client: { name: 'A', addressLines: [] },
    issueDate: '2026-01-01',
    items: [],
    discount: 0,
    currency: 'USD',
    createdAt: '',
    updatedAt: '',
    ...over,
  }) as Document

describe('isDue', () => {
  it('is due once the next issue date has arrived', () => {
    const doc = template({ recurrence: 'monthly', nextIssueDate: '2026-02-01' })
    expect(isDue(doc, '2026-01-31')).toBe(false)
    expect(isDue(doc, '2026-02-01')).toBe(true)
    expect(isDue(doc, '2026-03-05')).toBe(true)
  })

  it('is never due without a recurrence or a next date', () => {
    expect(isDue(template({ nextIssueDate: '2026-02-01' }), '2026-06-01')).toBe(false)
    expect(isDue(template({ recurrence: 'monthly' }), '2026-06-01')).toBe(false)
  })

  it('stops at the end date', () => {
    const doc = template({
      recurrence: 'monthly',
      nextIssueDate: '2026-04-01',
      recurrenceEndDate: '2026-03-31',
    })
    expect(isDue(doc, '2026-06-01')).toBe(false)
  })

  it('still generates the occurrence that falls on the end date', () => {
    const doc = template({
      recurrence: 'monthly',
      nextIssueDate: '2026-03-01',
      recurrenceEndDate: '2026-03-01',
    })
    expect(isDue(doc, '2026-03-01')).toBe(true)
  })
})
