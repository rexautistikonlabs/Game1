import { describe, expect, it } from 'vitest'
import { extractDate, extractFields, extractTotal, extractVendor, guessCategory } from './ocr'

/**
 * OCR field extraction is pure heuristics over noisy text, which makes it the
 * easiest thing in the app to break silently. These are real receipt shapes.
 */

const COFFEE = `HARBOR & FINCH COFFEE
310 PIKE STREET
SEATTLE, WA 98101
TEL (206) 555-0733
DATE: 03/14/2026  TIME: 09:42 AM
SERVER: DANA  TABLE: 4
2 CAPPUCCINO 9.00
1 ALMOND CROISSANT 4.75
1 AVOCADO TOAST 12.50
SUBTOTAL 37.50
SALES TAX 8.8% 3.30
TOTAL 40.80
VISA ****4417 40.80`

const GERMAN = `Bürobedarf Schmidt GmbH
Hauptstrasse 14
Rechnung
25.02.2026
Papier A4 2 x 4,50 9,00
Toner 1 x 89,90 89,90
Netto 98,90
MwSt 19% 18,79
Gesamt 117,69`

const UK = `RIDGELINE HARDWARE LTD
VAT Reg No. GB123456789
Invoice Date: 5 Jan 2026
Timber decking  1,240.00
Fixings          85.50
Subtotal      1,325.50
VAT @ 20%       265.10
AMOUNT DUE    1,590.60`

const FLIGHT = `ALASKA AIRLINES
E-TICKET RECEIPT
Mar 3, 2026
SEA - PDX  ONE WAY
FARE 249.00
FEES 40.00
GRAND TOTAL 289.00`

describe('extractVendor', () => {
  it('takes the shop name from the top of the receipt', () => {
    expect(extractVendor(COFFEE)).toBe('Harbor & Finch Coffee')
  })

  it('skips boilerplate headers like "RECEIPT"', () => {
    expect(extractVendor('*** CUSTOMER COPY ***\nRECEIPT\nRose City Print Shop\n2026-02-18')).toBe(
      'Rose City Print Shop',
    )
  })

  it('leaves already-capitalised names alone', () => {
    expect(extractVendor(GERMAN)).toBe('Bürobedarf Schmidt GmbH')
  })
})

describe('extractDate', () => {
  it('reads US month-first dates', () => {
    expect(extractDate(COFFEE)).toBe('2026-03-14')
  })

  it('reads European day-first dates with dots', () => {
    expect(extractDate(GERMAN)).toBe('2026-02-25')
  })

  it('reads spelled-out months in both orders', () => {
    expect(extractDate(UK)).toBe('2026-01-05')
    expect(extractDate(FLIGHT)).toBe('2026-03-03')
  })

  it('resolves an ambiguous date using the value that can only be a day', () => {
    expect(extractDate('Receipt\n25/02/2026\nTotal 10.00')).toBe('2026-02-25')
  })

  it('falls back to today when there is no date at all', () => {
    expect(extractDate('CASH SALE\nTOTAL 5.00')).toBe(new Date().toISOString().slice(0, 10))
  })
})

describe('extractTotal', () => {
  it('prefers the grand total over the subtotal', () => {
    expect(extractTotal(COFFEE)).toBe(40.8)
    expect(extractTotal('Subtotal 80.87\nTax 7.11\nTotal 87.98')).toBe(87.98)
  })

  it('understands "amount due" and thousands separators', () => {
    expect(extractTotal(UK)).toBe(1590.6)
  })

  it('handles comma decimal separators and non-English keywords', () => {
    expect(extractTotal(GERMAN)).toBe(117.69)
  })

  it('is not fooled by the cash tendered or the change given', () => {
    expect(extractTotal('300 COPIES 214.50\nTOTAL 214.50\nCASH 250.00\nCHANGE 35.50')).toBe(214.5)
  })

  it('ignores the year in a date when falling back to the largest amount', () => {
    expect(extractTotal('CORNER STORE\n2026-04-02\nSnacks 6.25')).toBe(6.25)
  })
})

describe('extractFields', () => {
  it('reads the tax amount, not the tax rate printed beside it', () => {
    expect(extractFields(COFFEE).taxAmount).toBe(3.3)
    expect(extractFields(UK).taxAmount).toBe(265.1)
  })

  it('does not mistake a tax registration number for an amount', () => {
    const fields = extractFields('NORTHWEST LEGAL LLP\nTax ID 91-1234567\n2026-02-10\nTotal 450.00')
    expect(fields.total).toBe(450)
    expect(fields.taxAmount).toBe(0)
  })

  it('leaves tax at zero when the receipt shows none', () => {
    expect(extractFields(FLIGHT).taxAmount).toBe(0)
  })
})

describe('guessCategory', () => {
  it('matches plural and singular vendor words alike', () => {
    expect(guessCategory('ALASKA AIRLINES')).toBe('Travel')
    expect(guessCategory('Cascade Airline')).toBe('Travel')
  })

  it('recognises the common expense types', () => {
    expect(guessCategory(COFFEE)).toBe('Meals & Entertainment')
    expect(guessCategory('ADOBE Creative Cloud subscription')).toBe('Software & Subscriptions')
    expect(guessCategory('Staples — copy paper and toner')).toBe('Office Supplies')
    expect(guessCategory('Cascade Credit Union service charge')).toBe('Bank & Payment Fees')
  })

  it('falls back to Other rather than guessing wildly', () => {
    expect(guessCategory('QRZ 4471 XV')).toBe('Other')
  })
})

// ---------------------------------------------------------------------------
// Regression tests from the code-review pass. Each of these was a real bug.
// ---------------------------------------------------------------------------

describe('amount parsing regressions', () => {
  it('does not truncate a four-figure amount printed without a separator', () => {
    // `\d{1,3}(?:[.,\s]\d{3})*` matched only "200" out of "2000.00".
    expect(extractTotal('SHOP\nTOTAL 2000.00')).toBe(2000)
    expect(extractTotal('SHOP\nTOTAL 1995.50')).toBe(1995.5)
    expect(extractTotal('SHOP\nTOTAL 12500.75')).toBe(12500.75)
  })

  it('still reads separated amounts in both conventions', () => {
    expect(extractTotal('SHOP\nAMOUNT DUE 1,590.60')).toBe(1590.6)
    expect(extractTotal('Laden\nGesamt 1.234,56')).toBe(1234.56)
  })

  it('does not mistake a four-digit total for a year', () => {
    // The bare-year strip used \b, which matched inside "2000.00".
    expect(extractTotal('SHOP\nTOTAL 2026.00')).toBe(2026)
    expect(extractTotal('SHOP\n2026-04-02\nTOTAL 1980.00')).toBe(1980)
  })

  it('still ignores a standalone year with no total keyword', () => {
    expect(extractTotal('CORNER STORE\n2026-04-02\nSnacks 6.25')).toBe(6.25)
  })
})

describe('total keyword handling', () => {
  it('treats "total incl. VAT" as the total, not a tax line', () => {
    expect(extractTotal('SHOP\nSubtotal 37.50\nTotal incl. VAT 40.80')).toBe(40.8)
    expect(extractTotal('SHOP\nTotal including tax  117.69')).toBe(117.69)
    expect(extractTotal('SHOP\nTotal (inc VAT) 90.00')).toBe(90)
  })

  it('still refuses a subtotal or a bare tax line', () => {
    expect(extractTotal('SHOP\nSubtotal 80.00\nTax 8.00\nTotal 88.00')).toBe(88)
  })
})

describe('identifier lines in the fallback', () => {
  it('ignores a phone number when no total keyword exists', () => {
    expect(extractTotal('CORNER STORE\nTEL (206) 555-0733\nSnacks 6.25')).toBe(6.25)
  })

  it('ignores a VAT registration number', () => {
    expect(extractTotal('SHOP LTD\nVAT No. GB123456789\nGoods 12.00')).toBe(12)
  })

  it('does not discard a line that merely mentions tax', () => {
    expect(extractTotal('SHOP\nPrices include tax\nBread 4.20')).toBe(4.2)
  })
})

describe('vendor capitalisation', () => {
  it('leaves short acronyms alone', () => {
    expect(extractVendor('IBM UK LTD\n2026-01-01\nTotal 10.00')).toBe('IBM UK LTD')
    expect(extractVendor('BP CONNECT\n2026-01-01\nTotal 40.00')).toBe('BP Connect')
  })

  it('does not capitalise the letter after an apostrophe', () => {
    expect(extractVendor("MCDONALD'S RESTAURANT\n2026-01-01\nTotal 8.00")).toBe(
      "Mcdonald's Restaurant",
    )
  })

  it('does not treat a short function word as an acronym', () => {
    expect(extractVendor('HARBOR AND FINCH COFFEE\n2026-01-01\nTotal 8.00')).toBe(
      'Harbor And Finch Coffee',
    )
  })

  it('leaves a name that is already mixed case untouched', () => {
    expect(extractVendor('Bürobedarf Schmidt GmbH\n25.02.2026')).toBe('Bürobedarf Schmidt GmbH')
  })
})

describe('guessCategory against a company list', () => {
  it('only returns a category the company actually has', () => {
    const available = ['Office Supplies', 'Other']
    // "Travel" is the natural guess, but this company has no Travel category.
    expect(guessCategory('ALASKA AIRLINES', available)).toBe('Other')
  })

  it('matches case-insensitively against the company list', () => {
    expect(guessCategory('ALASKA AIRLINES', ['travel', 'other'])).toBe('travel')
  })

  it('falls back to the first category when there is no Other', () => {
    expect(guessCategory('QRZ 4471 XV', ['Program Expenses', 'Grants'])).toBe('Program Expenses')
  })

  it('keeps the built-in behaviour when no list is supplied', () => {
    expect(guessCategory('ALASKA AIRLINES')).toBe('Travel')
    expect(guessCategory('QRZ 4471 XV')).toBe('Other')
  })
})
