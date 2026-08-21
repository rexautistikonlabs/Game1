import { db, getSetting, newId, seedCategories, setSetting } from './db'
import { addDays, today } from '../lib/format'
import type { Client, Company, Document, Expense, LineItem } from '../types'

const SEED_FLAG = 'seeded'
export const SAMPLE_TIP_FLAG = 'sampleTip'

/** Inline SVG logos keep the sample companies self-contained — no image files. */
function logoDataUrl(text: string, background: string, foreground = '#ffffff'): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160">
  <rect width="160" height="160" rx="34" fill="${background}"/>
  <text x="80" y="80" font-family="Inter, Helvetica, Arial, sans-serif" font-size="62"
        font-weight="700" fill="${foreground}" text-anchor="middle" dominant-baseline="central"
        letter-spacing="-2">${text}</text>
</svg>`
  return `data:image/svg+xml;base64,${btoa(svg)}`
}

const item = (
  description: string,
  quantity: number,
  unitPrice: number,
  taxRate: number,
): LineItem => ({ id: newId(), description, quantity, unitPrice, taxRate })

/**
 * Seeds two example companies the first time SimpleBooks opens, so the
 * company switcher, the lists and the dashboard all have something real to
 * show. Everything here is deletable — it is a demo, not a fixture.
 */
let seedPromise: Promise<void> | null = null

export function seedIfEmpty(): Promise<void> {
  // Concurrent callers share one run, so the examples can never double-insert.
  seedPromise ??= runSeed().finally(() => {
    seedPromise = null
  })
  return seedPromise
}

async function runSeed(): Promise<void> {
  if (await getSetting(SEED_FLAG, false)) return
  // A company already exists (e.g. restored from a backup) — never overwrite it.
  if ((await db.companies.count()) > 0) {
    await setSetting(SEED_FLAG, true)
    return
  }

  const now = new Date().toISOString()
  // One millisecond apart so the switcher's created-order is deterministic.
  const later = new Date(Date.now() + 1).toISOString()
  const t = today()

  const nonprofit: Company = {
    id: newId(),
    name: 'Nonprofit Example',
    legalName: 'Riverside Community Foundation, Inc.',
    type: 'nonprofit',
    logo: logoDataUrl('RC', '#0f766e'),
    addressLines: ['418 Willow Street', 'Suite 2B', 'Portland, OR 97209', 'United States'],
    email: 'finance@riverside-example.org',
    phone: '(503) 555-0142',
    website: 'riverside-example.org',
    taxId: 'EIN 84-2910477',
    currency: 'USD',
    brandColor: '#0f766e',
    paymentDetails:
      'Check payable to: Riverside Community Foundation, Inc.\nBank transfer — Cascade Credit Union\nRouting 323271234 · Account 4410098823',
    footerNote:
      'Riverside Community Foundation is a registered 501(c)(3) organization. ' +
      'Contributions are tax-deductible to the extent allowed by law.',
    defaultTaxRate: 0,
    invoicePrefix: 'RCF-INV-',
    receiptPrefix: 'RCF-RCT-',
    nextInvoiceNumber: 1004,
    nextReceiptNumber: 1003,
    paymentTermsDays: 30,
    createdAt: now,
  }

  const forProfit: Company = {
    id: newId(),
    name: 'For-Profit Example',
    legalName: 'Northlight Studio LLC',
    type: 'forprofit',
    logo: logoDataUrl('NS', '#1d4ed8'),
    addressLines: ['77 Harbor Way', 'Floor 4', 'Seattle, WA 98104', 'United States'],
    email: 'billing@northlight-example.com',
    phone: '(206) 555-0188',
    website: 'northlight-example.com',
    taxId: 'EIN 47-6620913',
    currency: 'USD',
    brandColor: '#1d4ed8',
    paymentDetails:
      'Bank transfer — Puget Sound Bank\nRouting 125108405 · Account 8890231764\nOr pay by card using the link in your email.',
    footerNote: 'Thank you for your business. Late payments accrue 1.5% interest per month.',
    defaultTaxRate: 8.8,
    invoicePrefix: 'NS-',
    receiptPrefix: 'NS-R-',
    nextInvoiceNumber: 1042,
    nextReceiptNumber: 1012,
    paymentTermsDays: 14,
    createdAt: later,
  }

  const clients: Client[] = [
    {
      id: newId(),
      companyId: nonprofit.id,
      name: 'Cascade Health Trust',
      email: 'grants@cascadehealth-example.org',
      phone: '(503) 555-0311',
      addressLines: ['1200 SW Market Street', 'Portland, OR 97201'],
      notes: 'Community wellness grant — reports due quarterly.',
      createdAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      name: 'Willamette School District',
      email: 'accounts.payable@wsd-example.org',
      phone: '(503) 555-0450',
      addressLines: ['905 Education Way', 'Beaverton, OR 97005'],
      notes: 'Purchase order required on every invoice.',
      createdAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      name: 'Marguerite Alvarez',
      email: 'm.alvarez@example.com',
      addressLines: ['22 Alder Court', 'Portland, OR 97214'],
      notes: 'Monthly sustaining donor since 2021.',
      createdAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      name: 'Harbor & Finch Coffee',
      email: 'ap@harborfinch-example.com',
      phone: '(206) 555-0733',
      addressLines: ['310 Pike Street', 'Seattle, WA 98101'],
      notes: 'Brand refresh retainer — invoices on the 1st.',
      createdAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      name: 'Ridgeline Outfitters',
      email: 'finance@ridgeline-example.com',
      phone: '(425) 555-0166',
      addressLines: ['4400 Evergreen Parkway', 'Bellevue, WA 98007'],
      createdAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      name: 'Juniper Dental Group',
      email: 'office@juniperdental-example.com',
      phone: '(206) 555-0925',
      addressLines: ['58 Boren Avenue N', 'Seattle, WA 98109'],
      notes: 'Prefers PDF invoices by email, no paper.',
      createdAt: now,
    },
  ]

  // Declared up front so the retainer invoices can all share it.
  const retainerSeriesId = newId()

  const snapshot = (client: Client) => ({
    name: client.name,
    email: client.email,
    phone: client.phone,
    addressLines: client.addressLines,
  })

  const [cascade, school, donor, harbor, ridgeline, juniper] = clients as [
    Client, Client, Client, Client, Client, Client,
  ]

  const documents: Document[] = [
    // ---- Nonprofit ----
    {
      id: newId(),
      companyId: nonprofit.id,
      kind: 'invoice',
      number: 'RCF-INV-1001',
      status: 'paid',
      clientId: cascade.id,
      client: snapshot(cascade),
      issueDate: addDays(t, -46),
      dueDate: addDays(t, -16),
      paidDate: addDays(t, -21),
      items: [
        item('Community wellness workshops — Q1 delivery', 12, 450, 0),
        item('Participant materials and printing', 1, 620, 0),
      ],
      discount: 0,
      notes: 'Grant agreement CHT-2024-118, milestone 1 of 4.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      kind: 'invoice',
      number: 'RCF-INV-1002',
      status: 'sent',
      clientId: school.id,
      client: snapshot(school),
      issueDate: addDays(t, -38),
      dueDate: addDays(t, -8),
      items: [
        item('After-school reading program — 6 week session', 6, 725, 0),
        item('Volunteer coordinator time', 24, 38, 0),
      ],
      discount: 250,
      notes: 'PO #WSD-77401. Discount reflects in-kind classroom space.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      kind: 'invoice',
      number: 'RCF-INV-1003',
      status: 'draft',
      clientId: cascade.id,
      client: snapshot(cascade),
      issueDate: t,
      dueDate: addDays(t, 30),
      items: [item('Community wellness workshops — Q2 delivery', 12, 465, 0)],
      discount: 0,
      notes: 'Grant agreement CHT-2024-118, milestone 2 of 4.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      kind: 'receipt',
      number: 'RCF-RCT-1001',
      status: 'paid',
      clientId: donor.id,
      client: snapshot(donor),
      issueDate: addDays(t, -12),
      paidDate: addDays(t, -12),
      paymentMethod: 'Card',
      items: [item('Charitable donation — general fund', 1, 250, 0)],
      discount: 0,
      notes: 'No goods or services were provided in exchange for this gift.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      kind: 'receipt',
      number: 'RCF-RCT-1002',
      status: 'paid',
      clientId: donor.id,
      client: snapshot(donor),
      issueDate: addDays(t, -3),
      paidDate: addDays(t, -3),
      paymentMethod: 'Bank Transfer',
      items: [item('Monthly sustaining gift', 1, 75, 0)],
      discount: 0,
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },

    // ---- For-profit ----
    {
      id: newId(),
      companyId: forProfit.id,
      kind: 'invoice',
      number: 'NS-1039',
      status: 'paid',
      clientId: harbor.id,
      client: snapshot(harbor),
      issueDate: addDays(t, -34),
      dueDate: addDays(t, -20),
      paidDate: addDays(t, -24),
      items: [
        item('Brand identity design — logo and marks', 1, 3800, 8.8),
        item('Packaging concepts (3 directions)', 3, 640, 8.8),
      ],
      discount: 0,
      notes: 'Phase 1 of the brand refresh.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      kind: 'invoice',
      number: 'NS-1040',
      // Deliberately past due, so the Overdue state is visible on first launch.
      status: 'sent',
      clientId: ridgeline.id,
      client: snapshot(ridgeline),
      issueDate: addDays(t, -29),
      dueDate: addDays(t, -15),
      items: [
        item('Product photography — half day', 1, 1450, 8.8),
        item('Retouching and delivery', 42, 22, 8.8),
        item('Studio rental pass-through', 1, 380, 0),
      ],
      discount: 0,
      notes: 'Shot list approved 4 weeks ago. Second reminder sent.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      kind: 'invoice',
      number: 'NS-1041',
      status: 'sent',
      clientId: juniper.id,
      client: snapshot(juniper),
      issueDate: addDays(t, -5),
      dueDate: addDays(t, 9),
      items: [
        item('Website redesign — discovery and wireframes', 1, 2600, 8.8),
        item('Copywriting for 8 pages', 8, 185, 8.8),
      ],
      discount: 200,
      notes: 'Returning-client credit applied.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
    // ---- A monthly retainer: two invoices already issued, the newest carrying
    // the recurrence. Dated ahead of today so opening the app does not
    // immediately generate a third.
    {
      id: retainerSeriesId,
      companyId: forProfit.id,
      kind: 'invoice',
      number: 'NS-1037',
      status: 'paid',
      clientId: harbor.id,
      client: snapshot(harbor),
      issueDate: addDays(t, -62),
      dueDate: addDays(t, -48),
      paidDate: addDays(t, -50),
      items: [item('Brand refresh retainer — monthly', 1, 1200, 8.8)],
      discount: 0,
      notes: 'Retainer, month 1 of 12.',
      currency: 'USD',
      seriesId: retainerSeriesId,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      kind: 'invoice',
      number: 'NS-1038',
      status: 'sent',
      clientId: harbor.id,
      client: snapshot(harbor),
      issueDate: addDays(t, -31),
      dueDate: addDays(t, -17),
      items: [item('Brand refresh retainer — monthly', 1, 1200, 8.8)],
      discount: 0,
      notes: 'Retainer, month 2 of 12.',
      currency: 'USD',
      // The active template: this is the invoice that decides when the next
      // one appears.
      recurrence: 'monthly',
      nextIssueDate: addDays(t, 12),
      seriesId: retainerSeriesId,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      kind: 'receipt',
      number: 'NS-R-1011',
      status: 'paid',
      clientId: harbor.id,
      client: snapshot(harbor),
      issueDate: addDays(t, -24),
      paidDate: addDays(t, -24),
      paymentMethod: 'Bank Transfer',
      items: [item('Payment received for invoice NS-1039', 1, 5893.44, 0)],
      discount: 0,
      notes: 'Paid in full, thank you.',
      currency: 'USD',
      createdAt: now,
      updatedAt: now,
    },
  ]

  const expenses: Expense[] = [
    {
      id: newId(),
      companyId: nonprofit.id,
      vendor: 'Rose City Print Shop',
      date: addDays(t, -9),
      total: 214.5,
      taxAmount: 0,
      category: 'Program Expenses',
      notes: 'Workshop handouts, 300 copies.',
      currency: 'USD',
      paymentMethod: 'Card',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      vendor: 'Cascade Credit Union',
      date: addDays(t, -6),
      total: 18,
      taxAmount: 0,
      category: 'Bank & Payment Fees',
      notes: 'Monthly account maintenance.',
      currency: 'USD',
      paymentMethod: 'Bank Transfer',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: nonprofit.id,
      vendor: 'Northwest Natural',
      date: addDays(t, -2),
      total: 132.87,
      taxAmount: 0,
      category: 'Rent & Utilities',
      currency: 'USD',
      paymentMethod: 'Bank Transfer',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      vendor: 'Adobe',
      date: addDays(t, -19),
      total: 87.98,
      taxAmount: 7.11,
      category: 'Software & Subscriptions',
      notes: 'Creative Cloud, 2 seats.',
      currency: 'USD',
      paymentMethod: 'Card',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      vendor: 'Pike Place Camera Rental',
      date: addDays(t, -15),
      total: 342.16,
      taxAmount: 27.66,
      category: 'Equipment',
      notes: 'Lens and lighting for the Ridgeline shoot.',
      currency: 'USD',
      paymentMethod: 'Card',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      vendor: 'Harbor & Finch Coffee',
      date: addDays(t, -4),
      total: 46.2,
      taxAmount: 3.74,
      category: 'Meals & Entertainment',
      notes: 'Client kickoff meeting.',
      currency: 'USD',
      paymentMethod: 'Card',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
    {
      id: newId(),
      companyId: forProfit.id,
      vendor: 'Alaska Airlines',
      date: addDays(t, -1),
      total: 289,
      taxAmount: 0,
      category: 'Travel',
      notes: 'Portland client visit.',
      currency: 'USD',
      paymentMethod: 'Card',
      source: 'manual',
      createdAt: now,
      updatedAt: now,
    },
  ]

  await db.transaction(
    'rw',
    [db.companies, db.clients, db.documents, db.expenses, db.settings],
    async () => {
      await db.companies.bulkAdd([nonprofit, forProfit])
      await db.clients.bulkAdd(clients)
      await db.documents.bulkAdd(documents)
      await db.expenses.bulkAdd(expenses)
      await setSetting(SEED_FLAG, true)
      await setSetting('activeCompanyId', nonprofit.id)
      // Tells the dashboard to explain that these two companies are examples.
      // Dismissing it (or resetting the demo data) flips this.
      await setSetting(SAMPLE_TIP_FLAG, true)
    },
  )

  // Outside the transaction above: seedCategories opens its own, and Dexie
  // does not allow a nested transaction on a table the outer one did not claim.
  await seedCategories(nonprofit.id)
  await seedCategories(forProfit.id)
}

/** Wipes everything and re-seeds — the "reset demo data" button in Settings. */
export async function resetToSampleData(): Promise<void> {
  await db.transaction(
    'rw',
    [db.companies, db.clients, db.documents, db.expenses, db.attachments, db.categories, db.settings],
    async () => {
      await Promise.all([
        db.companies.clear(),
        db.clients.clear(),
        db.documents.clear(),
        db.expenses.clear(),
        db.attachments.clear(),
        db.categories.clear(),
        db.settings.clear(),
      ])
    },
  )
  await seedIfEmpty()
}

export function blankCompany(): Company {
  const now = new Date().toISOString()
  return {
    id: newId(),
    name: '',
    type: 'forprofit',
    addressLines: [],
    currency: 'USD',
    brandColor: '#1d4ed8',
    defaultTaxRate: 0,
    invoicePrefix: 'INV-',
    receiptPrefix: 'RCT-',
    nextInvoiceNumber: 1,
    nextReceiptNumber: 1,
    paymentTermsDays: 30,
    createdAt: now,
  }
}
