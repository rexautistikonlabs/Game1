import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Download, Plus } from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card } from '../components/ui/Card'
import { DocumentRow, DocumentRowHeader } from '../components/DocumentRow'
import { EmptyState } from '../components/ui/EmptyState'
import { ExportDialog } from '../components/ExportDialog'
import { InvoiceIllustration, ReceiptIllustration, SearchIllustration } from '../components/ui/Illustrations'
import { PageHeader } from '../components/PageHeader'
import { SearchInput, Segmented } from '../components/ui/SearchInput'
import { ListSkeleton } from '../components/ui/Skeleton'
import { computeTotals, displayStatus, formatMoney } from '../lib/format'
import { useActiveCompany, useDocuments, useExpenses } from '../store/useCompanyData'
import type { DocumentKind } from '../types'

type StatusFilter = 'all' | 'draft' | 'sent' | 'paid' | 'overdue'

const COPY = {
  invoice: {
    title: 'Invoices',
    subtitle: 'What you have billed, and what is still owed.',
    newLabel: 'New invoice',
    emptyTitle: 'No invoices yet',
    emptyBody:
      'An invoice asks a client to pay. Create one and you can print it, email it, or mark it paid in a single click.',
    illustration: <InvoiceIllustration />,
  },
  receipt: {
    title: 'Receipts',
    subtitle: 'Proof of money you have already received.',
    newLabel: 'New receipt',
    emptyTitle: 'No receipts yet',
    emptyBody:
      'A receipt confirms a payment you have already taken — perfect for donations, deposits and cash sales.',
    illustration: <ReceiptIllustration />,
  },
} as const

/** The Invoices and Receipts pages are the same list with different words. */
export function Documents({ kind }: { kind: DocumentKind }) {
  const company = useActiveCompany()
  const documents = useDocuments(kind)
  const allDocuments = useDocuments()
  const expenses = useExpenses()
  const navigate = useNavigate()

  const [search, setSearch] = useState('')
  const [status, setStatus] = useState<StatusFilter>('all')
  const [exportOpen, setExportOpen] = useState(false)

  const copy = COPY[kind]

  const counts = useMemo(() => {
    const list = documents ?? []
    return {
      all: list.length,
      draft: list.filter((d) => displayStatus(d) === 'draft').length,
      sent: list.filter((d) => displayStatus(d) === 'sent').length,
      paid: list.filter((d) => displayStatus(d) === 'paid').length,
      overdue: list.filter((d) => displayStatus(d) === 'overdue').length,
    }
  }, [documents])

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase()
    return (documents ?? []).filter((doc) => {
      if (status !== 'all' && displayStatus(doc) !== status) return false
      if (!needle) return true
      return (
        doc.number.toLowerCase().includes(needle) ||
        doc.client.name.toLowerCase().includes(needle) ||
        (doc.notes ?? '').toLowerCase().includes(needle) ||
        doc.items.some((item) => item.description.toLowerCase().includes(needle))
      )
    })
  }, [documents, search, status])

  if (!company || !documents || !allDocuments || !expenses)
    return <ListSkeleton label={`Loading ${copy.title.toLowerCase()}`} />

  const filteredTotal = filtered.reduce((sum, doc) => sum + computeTotals(doc).total, 0)
  const statusOptions: { value: StatusFilter; label: string; count: number }[] = [
    { value: 'all', label: 'All', count: counts.all },
    { value: 'draft', label: 'Draft', count: counts.draft },
    { value: 'sent', label: 'Sent', count: counts.sent },
    ...(kind === 'invoice'
      ? [{ value: 'overdue' as const, label: 'Overdue', count: counts.overdue }]
      : []),
    { value: 'paid', label: 'Paid', count: counts.paid },
  ]

  return (
    <div>
      <PageHeader
        title={copy.title}
        subtitle={copy.subtitle}
        actions={
          <>
            <Button variant="secondary" onClick={() => setExportOpen(true)}>
              <Download className="h-4 w-4" aria-hidden />
              Export CSV
            </Button>
            <Button variant="brand" onClick={() => navigate(`/${kind}s/new`)}>
              <Plus className="h-4 w-4" aria-hidden />
              {copy.newLabel}
            </Button>
          </>
        }
      />

      {documents.length === 0 ? (
        <Card padded={false}>
          <EmptyState
            illustration={copy.illustration}
            title={copy.emptyTitle}
            description={copy.emptyBody}
            action={
              <Button variant="brand" size="lg" onClick={() => navigate(`/${kind}s/new`)}>
                <Plus className="h-4 w-4" aria-hidden />
                {copy.newLabel}
              </Button>
            }
          />
        </Card>
      ) : (
        <>
          <div className="mb-4 flex flex-wrap items-center gap-3">
            <Segmented value={status} onChange={setStatus} options={statusOptions} size="sm" />
            <SearchInput
              value={search}
              onChange={setSearch}
              placeholder={`Search ${copy.title.toLowerCase()}…`}
              className="ml-auto w-full sm:w-72"
            />
          </div>

          <Card padded={false}>
            {filtered.length ? (
              <>
                <DocumentRowHeader />
                <div className="divide-y">
                  {filtered.map((doc) => (
                    <DocumentRow key={doc.id} doc={doc} />
                  ))}
                </div>
                <div className="flex items-center justify-between border-t px-4 py-3 text-[13.5px]">
                  <span className="text-[color:var(--text-muted)]">
                    {filtered.length} of {documents.length} shown
                  </span>
                  <span className="tabular font-semibold">
                    {formatMoney(filteredTotal, company.currency)}
                  </span>
                </div>
              </>
            ) : (
              <EmptyState
                illustration={<SearchIllustration />}
                title="Nothing matches those filters"
                description="Try a different status, or clear the search box."
                action={
                  <Button
                    variant="secondary"
                    onClick={() => {
                      setSearch('')
                      setStatus('all')
                    }}
                  >
                    Clear filters
                  </Button>
                }
              />
            )}
          </Card>
        </>
      )}

      <ExportDialog
        open={exportOpen}
        onClose={() => setExportOpen(false)}
        company={company}
        documents={allDocuments}
        expenses={expenses}
        initialWhat={kind === 'invoice' ? 'invoices' : 'receipts'}
      />
    </div>
  )
}
