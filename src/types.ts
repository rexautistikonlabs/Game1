/** Every record in SimpleBooks belongs to exactly one company. */
export type CompanyType = 'nonprofit' | 'forprofit'

export interface Company {
  id: string
  name: string
  legalName?: string
  type: CompanyType
  /** Data-URL so the logo travels with the JSON backup. */
  logo?: string
  addressLines: string[]
  email?: string
  phone?: string
  website?: string
  /** EIN / VAT / Tax ID — printed on documents. */
  taxId?: string
  currency: string
  brandColor: string
  /** How to pay us — printed at the bottom of every invoice. */
  paymentDetails?: string
  /** Thank-you note / terms printed under the totals. */
  footerNote?: string
  defaultTaxRate: number
  invoicePrefix: string
  receiptPrefix: string
  nextInvoiceNumber: number
  nextReceiptNumber: number
  /** Net days used to pre-fill an invoice due date. */
  paymentTermsDays: number
  createdAt: string
}

export interface Client {
  id: string
  companyId: string
  name: string
  email?: string
  phone?: string
  addressLines: string[]
  notes?: string
  createdAt: string
}

export type DocumentKind = 'invoice' | 'receipt'
export type DocumentStatus = 'draft' | 'sent' | 'paid'

export interface LineItem {
  id: string
  description: string
  quantity: number
  unitPrice: number
  /** Percent, per line, so mixed-rate documents work. */
  taxRate: number
}

/** A snapshot of the client as it was when the document was issued, so
 *  editing or deleting a client never silently rewrites history. */
export interface PartySnapshot {
  name: string
  email?: string
  phone?: string
  addressLines: string[]
}

export interface Document {
  id: string
  companyId: string
  kind: DocumentKind
  number: string
  status: DocumentStatus
  clientId?: string
  client: PartySnapshot
  issueDate: string
  /** Invoices only. */
  dueDate?: string
  /** Receipts only — how the money arrived. */
  paymentMethod?: string
  /** Set when status becomes `paid`. */
  paidDate?: string
  items: LineItem[]
  /** Flat amount taken off the subtotal before tax. */
  discount: number
  notes?: string
  currency: string
  createdAt: string
  updatedAt: string
}

export interface Expense {
  id: string
  companyId: string
  vendor: string
  date: string
  /** Gross amount actually paid. */
  total: number
  /** Tax portion included in `total`, if known. */
  taxAmount: number
  category: string
  notes?: string
  currency: string
  paymentMethod?: string
  /** Key into the `attachments` table — the original scan. */
  attachmentId?: string
  /** Raw OCR text, kept so you can re-read a scan without re-running OCR. */
  ocrText?: string
  source: 'manual' | 'scan'
  createdAt: string
  updatedAt: string
}

export interface Attachment {
  id: string
  companyId: string
  name: string
  mimeType: string
  /** Data-URL of the original scan, so backups are self-contained. */
  data: string
  createdAt: string
}

export interface Setting {
  key: string
  value: unknown
}

/** Derived, never stored — totals are always recomputed from line items. */
export interface DocumentTotals {
  subtotal: number
  discount: number
  taxableBase: number
  tax: number
  total: number
}

export const EXPENSE_CATEGORIES = [
  'Office Supplies',
  'Travel',
  'Meals & Entertainment',
  'Software & Subscriptions',
  'Equipment',
  'Rent & Utilities',
  'Professional Services',
  'Marketing',
  'Postage & Shipping',
  'Program Expenses',
  'Insurance',
  'Bank & Payment Fees',
  'Other',
] as const

export const PAYMENT_METHODS = [
  'Card',
  'Cash',
  'Bank Transfer',
  'Check',
  'PayPal',
  'Other',
] as const
