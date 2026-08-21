import { forwardRef } from 'react'
import {
  computeTotals,
  formatDateLong,
  formatMoney,
  lineTotal,
  readableOn,
  taxRateSummary,
  withAlpha,
} from '../lib/format'
import type { Company, Document } from '../types'

/**
 * The printed document. Deliberately fixed to light "paper" colours in both
 * themes — an invoice is a piece of paper, and it must look identical whether
 * it goes to a printer, a PDF or a client's inbox.
 *
 * Sized to A4 (210mm) so what you see is exactly what prints.
 */
export const DocumentSheet = forwardRef<
  HTMLDivElement,
  { doc: Document; company: Company; className?: string }
>(function DocumentSheet({ doc, company, className }, ref) {
  const totals = computeTotals(doc)
  const isInvoice = doc.kind === 'invoice'
  const brand = company.brandColor || '#1d4ed8'
  const onBrand = readableOn(brand)
  const taxLabel = taxRateSummary(doc.items)

  return (
    <div
      ref={ref}
      data-print-root
      className={className}
      style={{
        width: '210mm',
        minHeight: '297mm',
        padding: '16mm 14mm',
        background: '#ffffff',
        color: '#15181c',
        boxSizing: 'border-box',
        fontSize: '10.5pt',
        lineHeight: 1.5,
      }}
    >
      {/* ---- Header: who we are, what this is ---- */}
      <header style={{ display: 'flex', justifyContent: 'space-between', gap: '16mm', alignItems: 'flex-start' }}>
        <div style={{ minWidth: 0 }}>
          {company.logo ? (
            <img
              src={company.logo}
              alt=""
              style={{ width: '18mm', height: '18mm', borderRadius: '4mm', objectFit: 'cover', marginBottom: '4mm' }}
            />
          ) : null}
          <div style={{ fontSize: '15pt', fontWeight: 700, letterSpacing: '-0.02em', lineHeight: 1.2 }}>
            {company.legalName || company.name}
          </div>
          <div style={{ marginTop: '2mm', color: '#4d565f', whiteSpace: 'pre-line' }}>
            {company.addressLines.filter(Boolean).join('\n')}
          </div>
          <div style={{ marginTop: '2mm', color: '#4d565f' }}>
            {[company.email, company.phone, company.website].filter(Boolean).join(' · ')}
          </div>
          {company.taxId ? (
            <div style={{ marginTop: '1mm', color: '#6b7681', fontSize: '9pt' }}>{company.taxId}</div>
          ) : null}
        </div>

        <div style={{ textAlign: 'right', flexShrink: 0 }}>
          <div
            style={{
              display: 'inline-block',
              background: brand,
              color: onBrand,
              padding: '2mm 5mm',
              borderRadius: '2mm',
              fontSize: '13pt',
              fontWeight: 700,
              letterSpacing: '0.08em',
              textTransform: 'uppercase',
            }}
          >
            {isInvoice ? 'Invoice' : 'Receipt'}
          </div>
          <table style={{ marginTop: '5mm', marginLeft: 'auto', borderCollapse: 'collapse', fontSize: '10pt' }}>
            <tbody>
              <Meta label="Number" value={doc.number} strong />
              <Meta label={isInvoice ? 'Issued' : 'Date'} value={formatDateLong(doc.issueDate)} />
              {isInvoice && doc.dueDate ? <Meta label="Due" value={formatDateLong(doc.dueDate)} /> : null}
              {!isInvoice && doc.paymentMethod ? <Meta label="Paid by" value={doc.paymentMethod} /> : null}
              {isInvoice && doc.status === 'paid' && doc.paidDate ? (
                <Meta label="Paid" value={formatDateLong(doc.paidDate)} />
              ) : null}
            </tbody>
          </table>
        </div>
      </header>

      {/* ---- Who it is for ---- */}
      <section style={{ marginTop: '12mm', display: 'flex', justifyContent: 'space-between', gap: '12mm' }}>
        <div>
          <div
            style={{
              fontSize: '8.5pt',
              fontWeight: 700,
              letterSpacing: '0.1em',
              textTransform: 'uppercase',
              color: '#98a2ad',
              marginBottom: '2mm',
            }}
          >
            {isInvoice ? 'Bill to' : 'Received from'}
          </div>
          <div style={{ fontSize: '12pt', fontWeight: 600 }}>{doc.client.name || '—'}</div>
          {doc.client.addressLines.filter(Boolean).length ? (
            <div style={{ marginTop: '1.5mm', color: '#4d565f', whiteSpace: 'pre-line' }}>
              {doc.client.addressLines.filter(Boolean).join('\n')}
            </div>
          ) : null}
          {doc.client.email ? (
            <div style={{ marginTop: '1.5mm', color: '#4d565f' }}>{doc.client.email}</div>
          ) : null}
          {doc.client.phone ? <div style={{ color: '#4d565f' }}>{doc.client.phone}</div> : null}
        </div>

        <div style={{ textAlign: 'right', flexShrink: 0 }}>
          <div
            style={{
              fontSize: '8.5pt',
              fontWeight: 700,
              letterSpacing: '0.1em',
              textTransform: 'uppercase',
              color: '#98a2ad',
              marginBottom: '2mm',
            }}
          >
            {isInvoice ? 'Amount due' : 'Amount paid'}
          </div>
          <div style={{ fontSize: '22pt', fontWeight: 700, letterSpacing: '-0.03em', color: brand, lineHeight: 1.1 }}>
            {formatMoney(isInvoice && doc.status === 'paid' ? 0 : totals.total, doc.currency)}
          </div>
          {isInvoice && doc.status === 'paid' ? (
            <div style={{ marginTop: '1.5mm', fontSize: '10pt', fontWeight: 600, color: '#047857' }}>
              Paid in full — thank you
            </div>
          ) : null}
        </div>
      </section>

      {/* ---- Line items ---- */}
      <table style={{ width: '100%', marginTop: '10mm', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ background: withAlpha(brand, 0.07) }}>
            <Th align="left" width="52%">Description</Th>
            <Th align="right" width="10%">Qty</Th>
            <Th align="right" width="16%">Unit price</Th>
            {taxLabel ? <Th align="right" width="8%">Tax</Th> : null}
            <Th align="right" width="18%">Amount</Th>
          </tr>
        </thead>
        <tbody>
          {doc.items.map((item) => (
            <tr key={item.id} className="avoid-break" style={{ borderBottom: '0.3mm solid #eef0f2' }}>
              <Td align="left" style={{ fontWeight: 500 }}>{item.description || '—'}</Td>
              <Td align="right">{item.quantity}</Td>
              <Td align="right">{formatMoney(item.unitPrice, doc.currency)}</Td>
              {taxLabel ? <Td align="right">{item.taxRate ? `${item.taxRate}%` : '—'}</Td> : null}
              <Td align="right" style={{ fontWeight: 600 }}>
                {formatMoney(lineTotal(item), doc.currency)}
              </Td>
            </tr>
          ))}
        </tbody>
      </table>

      {/* ---- Totals ---- */}
      <section className="avoid-break" style={{ marginTop: '6mm', display: 'flex', justifyContent: 'flex-end' }}>
        <table style={{ minWidth: '72mm', borderCollapse: 'collapse' }}>
          <tbody>
            <TotalRow label="Subtotal" value={formatMoney(totals.subtotal, doc.currency)} />
            {totals.discount > 0 ? (
              <TotalRow label="Discount" value={`−${formatMoney(totals.discount, doc.currency)}`} />
            ) : null}
            {totals.tax > 0 ? (
              <TotalRow
                label={taxLabel && taxLabel !== 'mixed' ? `Tax (${taxLabel})` : 'Tax'}
                value={formatMoney(totals.tax, doc.currency)}
              />
            ) : null}
            <tr>
              <td
                style={{
                  padding: '3mm 4mm 3mm 0',
                  borderTop: `0.6mm solid ${brand}`,
                  fontWeight: 700,
                  fontSize: '11.5pt',
                }}
              >
                Total
              </td>
              <td
                style={{
                  padding: '3mm 0',
                  borderTop: `0.6mm solid ${brand}`,
                  textAlign: 'right',
                  fontWeight: 700,
                  fontSize: '13pt',
                  fontVariantNumeric: 'tabular-nums',
                  letterSpacing: '-0.02em',
                }}
              >
                {formatMoney(totals.total, doc.currency)}
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      {/* ---- Notes, how to pay, footer ---- */}
      {doc.notes ? (
        <section className="avoid-break" style={{ marginTop: '10mm' }}>
          <Heading>Notes</Heading>
          <div style={{ whiteSpace: 'pre-line', color: '#3a4149' }}>{doc.notes}</div>
        </section>
      ) : null}

      {isInvoice && company.paymentDetails ? (
        <section
          className="avoid-break"
          style={{
            marginTop: '8mm',
            padding: '5mm',
            borderRadius: '3mm',
            background: withAlpha(brand, 0.05),
            border: `0.25mm solid ${withAlpha(brand, 0.25)}`,
          }}
        >
          <Heading>How to pay</Heading>
          <div style={{ whiteSpace: 'pre-line', color: '#3a4149' }}>{company.paymentDetails}</div>
        </section>
      ) : null}

      {company.footerNote ? (
        <footer
          style={{
            marginTop: '10mm',
            paddingTop: '4mm',
            borderTop: '0.25mm solid #e4e7eb',
            fontSize: '8.5pt',
            color: '#6b7681',
            whiteSpace: 'pre-line',
          }}
        >
          {company.footerNote}
        </footer>
      ) : null}
    </div>
  )
})

function Heading({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: '8.5pt',
        fontWeight: 700,
        letterSpacing: '0.1em',
        textTransform: 'uppercase',
        color: '#98a2ad',
        marginBottom: '2mm',
      }}
    >
      {children}
    </div>
  )
}

function Meta({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <tr>
      <td style={{ padding: '0.8mm 4mm 0.8mm 0', color: '#98a2ad', textAlign: 'right' }}>{label}</td>
      <td
        style={{
          padding: '0.8mm 0',
          textAlign: 'right',
          fontWeight: strong ? 700 : 500,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {value}
      </td>
    </tr>
  )
}

function Th({
  children,
  align,
  width,
}: {
  children: React.ReactNode
  align: 'left' | 'right'
  width: string
}) {
  return (
    <th
      style={{
        width,
        textAlign: align,
        padding: '2.5mm 3mm',
        fontSize: '8.5pt',
        fontWeight: 700,
        letterSpacing: '0.06em',
        textTransform: 'uppercase',
        color: '#4d565f',
      }}
    >
      {children}
    </th>
  )
}

function Td({
  children,
  align,
  style,
}: {
  children: React.ReactNode
  align: 'left' | 'right'
  style?: React.CSSProperties
}) {
  return (
    <td
      style={{
        textAlign: align,
        padding: '3mm',
        verticalAlign: 'top',
        fontVariantNumeric: 'tabular-nums',
        ...style,
      }}
    >
      {children}
    </td>
  )
}

function TotalRow({ label, value }: { label: string; value: string }) {
  return (
    <tr>
      <td style={{ padding: '1.5mm 4mm 1.5mm 0', color: '#4d565f' }}>{label}</td>
      <td
        style={{
          padding: '1.5mm 0',
          textAlign: 'right',
          fontWeight: 500,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {value}
      </td>
    </tr>
  )
}
