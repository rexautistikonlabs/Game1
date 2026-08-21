import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import {
  Download,
  Image as ImageIcon,
  Pencil,
  Plus,
  ScanLine,
  Trash2,
} from 'lucide-react'
import { Button, IconButton } from '../components/ui/Button'
import { Card, StatCard } from '../components/ui/Card'
import { Chip } from '../components/ui/Badge'
import { EmptyState } from '../components/ui/EmptyState'
import { ExpenseDialog } from '../components/ExpenseDialog'
import { ExportDialog } from '../components/ExportDialog'
import { Modal } from '../components/ui/Modal'
import { PageHeader } from '../components/PageHeader'
import { ScanIllustration, SearchIllustration } from '../components/ui/Illustrations'
import { ScanImportDialog } from '../components/ScanImportDialog'
import { SearchInput, Segmented } from '../components/ui/SearchInput'
import { useConfirm } from '../components/ui/Confirm'
import { db } from '../db/db'
import { formatDate, formatMoney, monthLabel, monthStart, today, yearStart } from '../lib/format'
import { useApp } from '../store/useApp'
import { useActiveCompany, useDocuments, useExpenses } from '../store/useCompanyData'
import { EXPENSE_CATEGORIES, type Expense } from '../types'

type Period = 'month' | 'year' | 'all'

/** Expenses are kept apart from invoices and receipts — money out, not money in. */
export function Expenses() {
  const company = useActiveCompany()
  const expenses = useExpenses()
  const documents = useDocuments()
  const [searchParams, setSearchParams] = useSearchParams()
  const toast = useApp((s) => s.toast)
  const { confirm, dialog } = useConfirm()

  const [scanOpen, setScanOpen] = useState(false)
  const [manualOpen, setManualOpen] = useState(false)
  const [editing, setEditing] = useState<Expense | undefined>()
  const [exportOpen, setExportOpen] = useState(false)
  const [viewingScan, setViewingScan] = useState<{ expense: Expense; image: string } | null>(null)

  const [search, setSearch] = useState('')
  const [period, setPeriod] = useState<Period>('month')
  const [category, setCategory] = useState('all')

  // The top bar and the Electron menu both link here with ?import=1.
  useEffect(() => {
    if (searchParams.get('import')) {
      setScanOpen(true)
      const next = new URLSearchParams(searchParams)
      next.delete('import')
      setSearchParams(next, { replace: true })
    }
  }, [searchParams, setSearchParams])

  const periodStart = period === 'month' ? monthStart() : period === 'year' ? yearStart() : '0000-01-01'

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase()
    return (expenses ?? []).filter((expense) => {
      if (expense.date < periodStart) return false
      if (category !== 'all' && expense.category !== category) return false
      if (!needle) return true
      return (
        expense.vendor.toLowerCase().includes(needle) ||
        expense.category.toLowerCase().includes(needle) ||
        (expense.notes ?? '').toLowerCase().includes(needle)
      )
    })
  }, [expenses, search, periodStart, category])

  if (!company || !expenses || !documents) return null

  const filteredTotal = filtered.reduce((sum, expense) => sum + expense.total, 0)
  const filteredTax = filtered.reduce((sum, expense) => sum + expense.taxAmount, 0)
  const scannedCount = filtered.filter((expense) => expense.source === 'scan').length

  const usedCategories = [...new Set(expenses.map((expense) => expense.category))].sort()

  const openScan = async (expense: Expense) => {
    if (!expense.attachmentId) return
    const attachment = await db.attachments.get(expense.attachmentId)
    if (!attachment) {
      toast('The original scan is no longer stored.', 'error')
      return
    }
    setViewingScan({ expense, image: attachment.data })
  }

  const remove = async (expense: Expense) => {
    const ok = await confirm({
      title: `Delete this expense?`,
      message: `${expense.vendor} — ${formatMoney(expense.total, expense.currency)} on ${formatDate(
        expense.date,
      )}. This also removes the scan, if there is one.`,
      confirmLabel: 'Delete',
      destructive: true,
    })
    if (!ok) return
    await db.transaction('rw', [db.expenses, db.attachments], async () => {
      if (expense.attachmentId) await db.attachments.delete(expense.attachmentId)
      await db.expenses.delete(expense.id)
    })
    toast('Expense deleted', 'info')
  }

  const periodName =
    period === 'month' ? monthLabel(today()) : period === 'year' ? 'this year' : 'all time'

  return (
    <div>
      <PageHeader
        title="Expenses"
        subtitle="Money out — kept separate from your invoices and receipts."
        actions={
          <>
            <Button variant="secondary" onClick={() => setExportOpen(true)}>
              <Download className="h-4 w-4" aria-hidden />
              Export CSV
            </Button>
            <Button
              variant="secondary"
              onClick={() => {
                setEditing(undefined)
                setManualOpen(true)
              }}
            >
              <Plus className="h-4 w-4" aria-hidden />
              Add manually
            </Button>
            <Button variant="brand" onClick={() => setScanOpen(true)}>
              <ScanLine className="h-4 w-4" aria-hidden />
              Import scan
            </Button>
          </>
        }
      />

      {expenses.length === 0 ? (
        <Card padded={false}>
          <EmptyState
            illustration={<ScanIllustration />}
            title="No expenses yet"
            description="Drop a photo or PDF of a paper receipt and SimpleBooks will read the vendor, date and total for you — no typing, no uploading."
            action={
              <Button variant="brand" size="lg" onClick={() => setScanOpen(true)}>
                <ScanLine className="h-4 w-4" aria-hidden />
                Import a scanned receipt
              </Button>
            }
            secondaryAction={
              <Button
                variant="secondary"
                size="lg"
                onClick={() => {
                  setEditing(undefined)
                  setManualOpen(true)
                }}
              >
                Add one by hand
              </Button>
            }
          />
        </Card>
      ) : (
        <>
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <StatCard
              label={`Spent — ${periodName}`}
              value={formatMoney(filteredTotal, company.currency)}
              hint={`${filtered.length} ${filtered.length === 1 ? 'expense' : 'expenses'}`}
            />
            <StatCard
              label="Tax included"
              value={formatMoney(filteredTax, company.currency)}
              hint="Recoverable, where applicable"
            />
            <StatCard
              label="From scans"
              value={String(scannedCount)}
              hint={`${filtered.length - scannedCount} entered by hand`}
            />
          </div>

          <div className="mb-4 flex flex-wrap items-center gap-3">
            <Segmented
              value={period}
              onChange={setPeriod}
              size="sm"
              options={[
                { value: 'month', label: 'This month' },
                { value: 'year', label: 'This year' },
                { value: 'all', label: 'All' },
              ]}
            />
            <select
              value={category}
              onChange={(event) => setCategory(event.target.value)}
              className="field h-9 w-auto py-1 text-[13.5px]"
              aria-label="Filter by category"
            >
              <option value="all">All categories</option>
              {(usedCategories.length ? usedCategories : EXPENSE_CATEGORIES).map((option) => (
                <option key={option} value={option}>
                  {option}
                </option>
              ))}
            </select>
            <SearchInput
              value={search}
              onChange={setSearch}
              placeholder="Search vendors and notes…"
              className="ml-auto w-full sm:w-72"
            />
          </div>

          <Card padded={false}>
            {filtered.length ? (
              <>
                <div className="flex items-center gap-4 border-b px-4 py-2.5 text-[11.5px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
                  <div className="hidden w-24 shrink-0 sm:block">Date</div>
                  <div className="flex-1">Vendor</div>
                  <div className="hidden w-44 shrink-0 md:block">Category</div>
                  <div className="w-24 shrink-0 text-right">Total</div>
                  <div className="w-[6.5rem] shrink-0" />
                </div>
                <div className="divide-y">
                  {filtered.map((expense) => (
                    <div
                      key={expense.id}
                      className="group flex items-center gap-4 px-4 py-3 transition hover:bg-black/[0.025] dark:hover:bg-white/[0.04]"
                    >
                      <div className="tabular hidden w-24 shrink-0 text-[13.5px] text-[color:var(--text-muted)] sm:block">
                        {formatDate(expense.date)}
                      </div>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <span className="truncate text-[14.5px] font-medium">{expense.vendor}</span>
                          {expense.source === 'scan' ? (
                            <Chip tone="brand" className="shrink-0">
                              <ScanLine className="h-3 w-3" aria-hidden />
                              Scanned
                            </Chip>
                          ) : null}
                        </div>
                        <div className="mt-0.5 truncate text-[12.5px] text-[color:var(--text-muted)]">
                          {/* On a phone the date and category live here, since
                              their own columns are hidden at that width. */}
                          <span className="sm:hidden">
                            {formatDate(expense.date)} · {expense.category}
                            {expense.notes ? ' · ' : ''}
                          </span>
                          {expense.notes}
                        </div>
                      </div>
                      <div className="hidden w-44 shrink-0 text-[13.5px] text-[color:var(--text-muted)] md:block">
                        {expense.category}
                      </div>
                      <div className="tabular w-24 shrink-0 text-right text-[14.5px] font-semibold">
                        {formatMoney(expense.total, expense.currency)}
                      </div>
                      <div className="flex w-[6.5rem] shrink-0 items-center justify-end gap-0.5 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100">
                        {expense.attachmentId ? (
                          <IconButton
                            variant="ghost"
                            size="sm"
                            onClick={() => void openScan(expense)}
                            aria-label={`View the scan for ${expense.vendor}`}
                            title="View scan"
                          >
                            <ImageIcon className="h-4 w-4" aria-hidden />
                          </IconButton>
                        ) : null}
                        <IconButton
                          variant="ghost"
                          size="sm"
                          onClick={() => {
                            setEditing(expense)
                            setManualOpen(true)
                          }}
                          aria-label={`Edit ${expense.vendor}`}
                          title="Edit"
                        >
                          <Pencil className="h-4 w-4" aria-hidden />
                        </IconButton>
                        <IconButton
                          variant="ghost"
                          size="sm"
                          onClick={() => void remove(expense)}
                          aria-label={`Delete ${expense.vendor}`}
                          title="Delete"
                          className="hover:text-red-600"
                        >
                          <Trash2 className="h-4 w-4" aria-hidden />
                        </IconButton>
                      </div>
                    </div>
                  ))}
                </div>
                <div className="flex items-center justify-between border-t px-4 py-3 text-[13.5px]">
                  <span className="text-[color:var(--text-muted)]">
                    {filtered.length} of {expenses.length} shown
                  </span>
                  <span className="tabular font-semibold">
                    {formatMoney(filteredTotal, company.currency)}
                  </span>
                </div>
              </>
            ) : (
              <EmptyState
                illustration={<SearchIllustration />}
                title="Nothing in that range"
                description="Try a wider period, another category, or clear the search box."
                action={
                  <Button
                    variant="secondary"
                    onClick={() => {
                      setSearch('')
                      setCategory('all')
                      setPeriod('all')
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

      <ScanImportDialog open={scanOpen} onClose={() => setScanOpen(false)} company={company} />
      <ExpenseDialog
        open={manualOpen}
        onClose={() => {
          setManualOpen(false)
          setEditing(undefined)
        }}
        company={company}
        expense={editing}
      />
      <ExportDialog
        open={exportOpen}
        onClose={() => setExportOpen(false)}
        company={company}
        documents={documents}
        expenses={expenses}
        initialWhat="expenses"
      />
      <Modal
        open={viewingScan !== null}
        onClose={() => setViewingScan(null)}
        title={viewingScan ? `Scan — ${viewingScan.expense.vendor}` : ''}
        description={
          viewingScan
            ? `${formatDate(viewingScan.expense.date)} · ${formatMoney(
                viewingScan.expense.total,
                viewingScan.expense.currency,
              )}`
            : undefined
        }
        size="lg"
      >
        {viewingScan ? (
          <img
            src={viewingScan.image}
            alt={`Receipt from ${viewingScan.expense.vendor}`}
            className="mx-auto max-h-[65vh] rounded-xl border object-contain"
            style={{ background: 'var(--surface-2)' }}
          />
        ) : null}
      </Modal>
      {dialog}
    </div>
  )
}
