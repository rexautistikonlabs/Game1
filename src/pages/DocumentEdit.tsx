import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { ArrowLeft, Eye, Save } from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card, SectionTitle } from '../components/ui/Card'
import { ClientPicker } from '../components/ClientPicker'
import { DocumentSheet } from '../components/DocumentSheet'
import { Field, Input, MoneyInput, Select, Textarea } from '../components/ui/Input'
import { LineItemsEditor } from '../components/LineItemsEditor'
import { Segmented } from '../components/ui/SearchInput'
import { SheetPreview } from '../components/SheetPreview'
import { EditorSkeleton } from '../components/ui/Skeleton'
import { claimNextNumber, db, newId } from '../db/db'
import { addDays, computeTotals, currencySymbol, formatMoney, today } from '../lib/format'
import { useApp } from '../store/useApp'
import { useActiveCompany, useClients, useDocument } from '../store/useCompanyData'
import { PAYMENT_METHODS, type Document, type DocumentKind, type DocumentStatus } from '../types'

/** A brand-new document, pre-filled from the company's defaults. */
function draftDocument(kind: DocumentKind, company: {
  id: string
  currency: string
  defaultTaxRate: number
  paymentTermsDays: number
}): Document {
  const issueDate = today()
  const now = new Date().toISOString()
  return {
    id: newId(),
    companyId: company.id,
    kind,
    // Filled in from the company's counter the moment it is first saved.
    number: '',
    status: kind === 'receipt' ? 'paid' : 'draft',
    client: { name: '', email: '', phone: '', addressLines: [] },
    issueDate,
    dueDate: kind === 'invoice' ? addDays(issueDate, company.paymentTermsDays) : undefined,
    paymentMethod: kind === 'receipt' ? 'Bank Transfer' : undefined,
    paidDate: kind === 'receipt' ? issueDate : undefined,
    items: [{ id: newId(), description: '', quantity: 1, unitPrice: 0, taxRate: company.defaultTaxRate }],
    discount: 0,
    notes: '',
    currency: company.currency,
    createdAt: now,
    updatedAt: now,
  }
}

/**
 * Create or edit an invoice/receipt. Form on the left, the real printed sheet
 * on the right, updating as you type — so there is never a surprise at print
 * time.
 */
export function DocumentEdit({ kind: newKind }: { kind?: DocumentKind }) {
  const { id } = useParams()
  const [searchParams] = useSearchParams()
  const navigate = useNavigate()
  const company = useActiveCompany()
  const clients = useClients()
  const existing = useDocument(id)
  const toast = useApp((s) => s.toast)

  const [draft, setDraft] = useState<Document | null>(null)
  const [saveClient, setSaveClient] = useState(false)
  const [errors, setErrors] = useState<{ client?: string; items?: string }>({})
  const [saving, setSaving] = useState(false)
  const [showPreview, setShowPreview] = useState(false)
  // `null` means "follow the company default"; a boolean is an explicit choice.
  const [taxColumn, setTaxColumn] = useState<boolean | null>(null)

  // Seed the draft once: either a fresh document, a copy of another one
  // (?duplicate=…), or the document being edited.
  useEffect(() => {
    if (draft || !company) return

    if (id) {
      if (existing === undefined) return
      if (existing === null) {
        toast('That document no longer exists.', 'error')
        navigate('/invoices', { replace: true })
        return
      }
      setDraft(structuredClone(existing))
      return
    }

    const duplicateId = searchParams.get('duplicate')
    if (duplicateId) {
      void db.documents.get(duplicateId).then((source) => {
        if (!source) {
          setDraft(draftDocument(newKind ?? 'invoice', company))
          return
        }
        const now = new Date().toISOString()
        setDraft({
          ...structuredClone(source),
          id: newId(),
          number: '',
          status: source.kind === 'receipt' ? 'paid' : 'draft',
          issueDate: today(),
          dueDate:
            source.kind === 'invoice' ? addDays(today(), company.paymentTermsDays) : undefined,
          paidDate: source.kind === 'receipt' ? today() : undefined,
          items: source.items.map((item) => ({ ...item, id: newId() })),
          createdAt: now,
          updatedAt: now,
        })
      })
      return
    }

    const fresh = draftDocument(newKind ?? 'invoice', company)

    // Arriving from a client card (?client=…) should pre-fill who this is for.
    const clientId = searchParams.get('client')
    if (clientId) {
      void db.clients.get(clientId).then((client) => {
        setDraft(
          client
            ? {
                ...fresh,
                clientId: client.id,
                client: {
                  name: client.name,
                  email: client.email,
                  phone: client.phone,
                  addressLines: client.addressLines,
                },
              }
            : fresh,
        )
      })
      return
    }

    setDraft(fresh)
  }, [company, draft, existing, id, navigate, newKind, searchParams, toast])

  const totals = useMemo(
    () => (draft ? computeTotals(draft) : { subtotal: 0, discount: 0, taxableBase: 0, tax: 0, total: 0 }),
    [draft],
  )

  if (!company || !clients || !draft) return <EditorSkeleton />

  const isNew = !id
  const isInvoice = draft.kind === 'invoice'
  const showTax =
    taxColumn ?? (company.defaultTaxRate > 0 || draft.items.some((item) => item.taxRate > 0))
  const patch = (changes: Partial<Document>) => setDraft({ ...draft, ...changes })

  const switchKind = (kind: DocumentKind) => {
    if (kind === draft.kind) return
    patch({
      kind,
      // Numbering is per type, so an existing document gets a fresh number on save.
      number: '',
      status: kind === 'receipt' ? 'paid' : draft.status === 'paid' ? 'paid' : 'draft',
      dueDate: kind === 'invoice' ? addDays(draft.issueDate, company.paymentTermsDays) : undefined,
      paymentMethod: kind === 'receipt' ? (draft.paymentMethod ?? 'Bank Transfer') : undefined,
      paidDate: kind === 'receipt' ? draft.issueDate : draft.paidDate,
    })
  }

  const changeStatus = (status: DocumentStatus) =>
    patch({
      status,
      // Marking something paid should record *when*, without another field to fill.
      paidDate: status === 'paid' ? (draft.paidDate ?? today()) : undefined,
    })

  const save = async () => {
    const nextErrors: typeof errors = {}
    if (!draft.client.name.trim()) {
      nextErrors.client = isInvoice ? 'Who is this invoice for?' : 'Who paid you?'
    }
    if (!draft.items.some((item) => item.description.trim() || item.unitPrice > 0)) {
      nextErrors.items = 'Add at least one line with a description or an amount.'
    }
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length) {
      toast('Please fix the highlighted fields.', 'error')
      return
    }

    setSaving(true)
    try {
      // A number is claimed on first save only, so drafts never burn numbers.
      const number = draft.number || (await claimNextNumber(company.id, draft.kind))

      let clientId = draft.clientId
      if (saveClient && !clientId) {
        clientId = newId()
        await db.clients.add({
          id: clientId,
          companyId: company.id,
          name: draft.client.name.trim(),
          email: draft.client.email?.trim() || undefined,
          phone: draft.client.phone?.trim() || undefined,
          addressLines: draft.client.addressLines.filter(Boolean),
          createdAt: new Date().toISOString(),
        })
      }

      const record: Document = {
        ...draft,
        number,
        clientId,
        client: {
          ...draft.client,
          name: draft.client.name.trim(),
          addressLines: draft.client.addressLines.filter((line) => line.trim()),
        },
        items: draft.items.filter((item) => item.description.trim() || item.unitPrice > 0),
        discount: Number(draft.discount) || 0,
        updatedAt: new Date().toISOString(),
      }

      await db.documents.put(record)
      toast(`${isInvoice ? 'Invoice' : 'Receipt'} ${number} saved`)
      navigate(`/documents/${record.id}`, { replace: true })
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not save.', 'error')
    } finally {
      setSaving(false)
    }
  }

  const previewDoc: Document = {
    ...draft,
    number: draft.number || `${isInvoice ? company.invoicePrefix : company.receiptPrefix}${String(
      isInvoice ? company.nextInvoiceNumber : company.nextReceiptNumber,
    ).padStart(4, '0')}`,
  }

  return (
    <div>
      {/* ---- Sticky action bar ---- */}
      <div className="mb-6 flex flex-wrap items-center gap-3">
        <Button variant="ghost" size="sm" onClick={() => navigate(-1)}>
          <ArrowLeft className="h-4 w-4" aria-hidden />
          Back
        </Button>
        <div className="min-w-0">
          <h1 className="truncate text-[22px] font-semibold leading-tight tracking-[-0.02em]">
            {isNew ? `New ${draft.kind}` : `Edit ${draft.number}`}
          </h1>
          <p className="text-[13px] text-[color:var(--text-muted)]">
            {company.name} · {formatMoney(totals.total, draft.currency)}
          </p>
        </div>
        <div className="ml-auto flex items-center gap-2.5">
          <Button
            variant="secondary"
            onClick={() => setShowPreview((v) => !v)}
            className="xl:hidden"
          >
            <Eye className="h-4 w-4" aria-hidden />
            {showPreview ? 'Hide preview' : 'Preview'}
          </Button>
          <Button variant="brand" size="lg" onClick={save} loading={saving}>
            <Save className="h-4 w-4" aria-hidden />
            Save
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1fr)_minmax(0,26rem)]">
        {/* ---- Form ---- */}
        <div className="space-y-5">
          <Card className="space-y-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <Segmented
                value={draft.kind}
                onChange={switchKind}
                options={[
                  { value: 'invoice', label: 'Invoice' },
                  { value: 'receipt', label: 'Receipt' },
                ]}
              />
              <p className="text-[13px] text-[color:var(--text-muted)]">
                {isInvoice ? 'A request for payment.' : 'Proof of a payment received.'}
              </p>
            </div>

            <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <Field label={isInvoice ? 'Issue date' : 'Date'}>
                <Input
                  type="date"
                  value={draft.issueDate}
                  onChange={(event) => {
                    const issueDate = event.target.value
                    patch({
                      issueDate,
                      dueDate: isInvoice
                        ? addDays(issueDate, company.paymentTermsDays)
                        : undefined,
                      paidDate: draft.kind === 'receipt' ? issueDate : draft.paidDate,
                    })
                  }}
                />
              </Field>

              {isInvoice ? (
                <Field label="Due date" hint={`Net ${company.paymentTermsDays} by default.`}>
                  <Input
                    type="date"
                    value={draft.dueDate ?? ''}
                    onChange={(event) => patch({ dueDate: event.target.value })}
                  />
                </Field>
              ) : (
                <Field label="Paid by">
                  <Select
                    value={draft.paymentMethod ?? ''}
                    onChange={(event) => patch({ paymentMethod: event.target.value })}
                  >
                    {PAYMENT_METHODS.map((method) => (
                      <option key={method} value={method}>
                        {method}
                      </option>
                    ))}
                  </Select>
                </Field>
              )}

              <Field label="Status">
                <Select
                  value={draft.status}
                  onChange={(event) => changeStatus(event.target.value as DocumentStatus)}
                >
                  <option value="draft">Draft</option>
                  <option value="sent">Sent</option>
                  <option value="paid">Paid</option>
                </Select>
              </Field>
            </div>
          </Card>

          <Card className="space-y-5">
            <SectionTitle title={isInvoice ? 'Bill to' : 'Received from'} />
            <ClientPicker
              clients={clients}
              value={draft.client}
              clientId={draft.clientId}
              onChange={(client, clientId) => {
                setDraft({ ...draft, client, clientId })
                setErrors((prev) => ({ ...prev, client: undefined }))
              }}
              saveToClients={saveClient}
              onSaveToClientsChange={setSaveClient}
              label={isInvoice ? 'Client name' : 'Paid by'}
              error={errors.client}
            />
          </Card>

          <Card className="space-y-5">
            <SectionTitle
              title="Line items"
              subtitle={errors.items}
              className={errors.items ? '[&_p]:text-red-600 dark:[&_p]:text-red-400' : undefined}
            />
            <LineItemsEditor
              items={draft.items}
              currency={draft.currency}
              defaultTaxRate={company.defaultTaxRate}
              showTax={showTax}
              onToggleTax={() => setTaxColumn(!showTax)}
              onChange={(items) => {
                setDraft({ ...draft, items })
                setErrors((prev) => ({ ...prev, items: undefined }))
              }}
            />

            <div className="grid grid-cols-1 gap-5 border-t pt-5 sm:grid-cols-2">
              <Field label="Discount" hint="A flat amount off the subtotal, before tax.">
                <MoneyInput
                  symbol={currencySymbol(draft.currency)}
                  value={draft.discount || ''}
                  min="0"
                  placeholder="0.00"
                  onChange={(event) => patch({ discount: Number(event.target.value) })}
                />
              </Field>

              <dl className="space-y-1.5 self-end text-[14px]">
                <Row label="Subtotal" value={formatMoney(totals.subtotal, draft.currency)} />
                {totals.discount > 0 ? (
                  <Row label="Discount" value={`−${formatMoney(totals.discount, draft.currency)}`} />
                ) : null}
                {totals.tax > 0 ? (
                  <Row label="Tax" value={formatMoney(totals.tax, draft.currency)} />
                ) : null}
                <div className="flex items-baseline justify-between border-t pt-2">
                  <dt className="font-semibold">Total</dt>
                  <dd className="tabular text-[19px] font-semibold tracking-[-0.02em]">
                    {formatMoney(totals.total, draft.currency)}
                  </dd>
                </div>
              </dl>
            </div>
          </Card>

          <Card>
            <Field
              label="Notes"
              hint="Printed under the totals — a PO number, a thank-you, payment terms."
            >
              <Textarea
                rows={3}
                value={draft.notes ?? ''}
                onChange={(event) => patch({ notes: event.target.value })}
                placeholder="Thank you for your business."
              />
            </Field>
          </Card>
        </div>

        {/* ---- Live preview ---- */}
        <div className={showPreview ? '' : 'hidden xl:block'}>
          <div className="xl:sticky xl:top-32">
            <p className="mb-2.5 text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              Live preview
            </p>
            <SheetPreview className="rounded-lg">
              <DocumentSheet doc={previewDoc} company={company} />
            </SheetPreview>
          </div>
        </div>
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between">
      <dt className="text-[color:var(--text-muted)]">{label}</dt>
      <dd className="tabular font-medium">{value}</dd>
    </div>
  )
}
