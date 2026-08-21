import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { AlertTriangle, ArrowDownRight, ArrowUpRight, Download, Minus } from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card, SectionTitle, StatCard } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Field, Input, Select } from '../components/ui/Input'
import { InvoiceIllustration } from '../components/ui/Illustrations'
import { PageHeader } from '../components/PageHeader'
import { ListSkeleton } from '../components/ui/Skeleton'
import { formatDate, formatMoney, monthLabel } from '../lib/format'
import {
  buildReport,
  presetRange,
  reportToCsv,
  RANGE_PRESET_LABELS,
  type RangePreset,
} from '../lib/reports'
import { saveFile, slugify } from '../lib/download'
import { useApp } from '../store/useApp'
import { useActiveCompany, useDocuments, useExpenses } from '../store/useCompanyData'

/**
 * Deliberately calm: numbers and tables, no chart library. The only graphic is
 * a proportional bar drawn behind each month's figures, which costs nothing and
 * makes the shape of the year readable at a glance.
 */
export function Reports() {
  const company = useActiveCompany()
  const documents = useDocuments()
  const expenses = useExpenses()
  const toast = useApp((s) => s.toast)

  const [preset, setPreset] = useState<RangePreset>('this-year')
  const [customFrom, setCustomFrom] = useState(presetRange('this-month').from)
  const [customTo, setCustomTo] = useState(presetRange('this-month').to)
  const [busy, setBusy] = useState(false)

  const range = useMemo(
    () => (preset === 'custom' ? { from: customFrom, to: customTo } : presetRange(preset)),
    [preset, customFrom, customTo],
  )

  const report = useMemo(
    () => buildReport(documents ?? [], expenses ?? [], range),
    [documents, expenses, range],
  )

  if (!company || !documents || !expenses) return <ListSkeleton label="Loading reports" rows={4} />

  const currency = company.currency
  const hasAnything = documents.length > 0 || expenses.length > 0
  // The scale for the month bars: whichever single figure is largest.
  const peak = Math.max(1, ...report.months.map((m) => Math.max(m.income, m.expenses)))

  const download = async () => {
    setBusy(true)
    try {
      const csv = reportToCsv(report, company.name, currency)
      const label = preset === 'all' ? 'all-time' : `${range.from}-to-${range.to}`
      const saved = await saveFile(
        `${slugify(company.name)}-report-${label}.csv`,
        csv,
        'text/csv;charset=utf-8',
      )
      if (saved) toast('Report exported')
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Export failed.', 'error')
    } finally {
      setBusy(false)
    }
  }

  const rangeLabel =
    preset === 'all' ? 'all time' : `${formatDate(range.from)} – ${formatDate(range.to)}`

  return (
    <div>
      <PageHeader
        title="Reports"
        subtitle={`${company.name} · ${rangeLabel}`}
        actions={
          <Button variant="secondary" onClick={download} loading={busy} disabled={!hasAnything}>
            <Download className="h-4 w-4" aria-hidden />
            Export CSV
          </Button>
        }
      />

      {!hasAnything ? (
        <Card padded={false}>
          <EmptyState
            illustration={<InvoiceIllustration />}
            title="Nothing to report yet"
            description="Once you have an invoice or an expense on the books, this page shows what came in, what went out, and what you are still owed."
            action={
              <Link to="/invoices/new">
                <Button variant="brand" size="lg">
                  Create your first invoice
                </Button>
              </Link>
            }
          />
        </Card>
      ) : (
        <>
          {/* ---- Range filter ---- */}
          <Card className="mb-6">
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <Field label="Period">
                <Select
                  value={preset}
                  onChange={(event) => setPreset(event.target.value as RangePreset)}
                >
                  {(Object.keys(RANGE_PRESET_LABELS) as RangePreset[]).map((option) => (
                    <option key={option} value={option}>
                      {RANGE_PRESET_LABELS[option]}
                    </option>
                  ))}
                </Select>
              </Field>

              {preset === 'custom' ? (
                <>
                  <Field label="From">
                    <Input
                      type="date"
                      value={customFrom}
                      max={customTo}
                      onChange={(event) => setCustomFrom(event.target.value)}
                    />
                  </Field>
                  <Field label="To">
                    <Input
                      type="date"
                      value={customTo}
                      min={customFrom}
                      onChange={(event) => setCustomTo(event.target.value)}
                    />
                  </Field>
                </>
              ) : null}
            </div>
          </Card>

          {/* ---- Headline numbers ---- */}
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <StatCard
              label="Income received"
              value={formatMoney(report.income, currency)}
              hint={`${report.paidCount} paid ${report.paidCount === 1 ? 'document' : 'documents'}`}
              icon={<ArrowUpRight className="h-4 w-4" aria-hidden />}
              tone="positive"
            />
            <StatCard
              label="Expenses"
              value={formatMoney(report.expenses, currency)}
              hint={`${report.expenseCount} recorded`}
              icon={<ArrowDownRight className="h-4 w-4" aria-hidden />}
            />
            <StatCard
              label="Net"
              value={formatMoney(report.net, currency)}
              hint={report.net >= 0 ? 'Income minus expenses' : 'Spending exceeded income'}
              icon={<Minus className="h-4 w-4" aria-hidden />}
              tone={report.net >= 0 ? 'brand' : 'warning'}
            />
            <StatCard
              label="Outstanding now"
              value={formatMoney(report.outstanding, currency)}
              hint={
                report.overdueCount
                  ? `${formatMoney(report.overdue, currency)} of it overdue`
                  : `${report.outstandingCount} unpaid, none late`
              }
              icon={<AlertTriangle className="h-4 w-4" aria-hidden />}
              tone={report.overdueCount ? 'warning' : 'neutral'}
            />
          </div>

          <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
            {/* ---- Income vs expenses, month by month ---- */}
            <Card padded={false} className="min-w-0">
              <div className="px-5 pb-4 pt-5">
                <SectionTitle
                  title="Income and expenses"
                  subtitle="Money received against money spent, by month."
                />
              </div>

              {report.months.length ? (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[30rem] border-collapse text-[14px]">
                    <thead>
                      <tr className="border-b text-[11.5px] uppercase tracking-wider text-[color:var(--text-subtle)]">
                        <th className="px-5 py-2.5 text-left font-semibold">Month</th>
                        <th className="px-3 py-2.5 text-right font-semibold">In</th>
                        <th className="px-3 py-2.5 text-right font-semibold">Out</th>
                        <th className="px-5 py-2.5 text-right font-semibold">Net</th>
                      </tr>
                    </thead>
                    <tbody>
                      {report.months.map((row) => (
                        <tr key={row.month} className="border-b last:border-0">
                          <td className="px-5 py-3">
                            <div className="font-medium">{monthLabel(`${row.month}-01`)}</div>
                            {/* Two proportional bars: no library, just widths. */}
                            <div className="mt-1.5 space-y-1" aria-hidden>
                              <div
                                className="h-1.5 rounded-full bg-emerald-500/70"
                                style={{ width: `${Math.max(2, (row.income / peak) * 100)}%` }}
                              />
                              <div
                                className="h-1.5 rounded-full bg-ink-400/60"
                                style={{ width: `${Math.max(2, (row.expenses / peak) * 100)}%` }}
                              />
                            </div>
                          </td>
                          <td className="tabular px-3 py-3 text-right align-top">
                            {formatMoney(row.income, currency)}
                          </td>
                          <td className="tabular px-3 py-3 text-right align-top text-[color:var(--text-muted)]">
                            {formatMoney(row.expenses, currency)}
                          </td>
                          <td
                            className={`tabular px-5 py-3 text-right align-top font-semibold ${
                              row.net < 0 ? 'text-amber-600 dark:text-amber-400' : ''
                            }`}
                          >
                            {formatMoney(row.net, currency)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                    <tfoot>
                      <tr className="border-t-2 font-semibold">
                        <td className="px-5 py-3">Total</td>
                        <td className="tabular px-3 py-3 text-right">
                          {formatMoney(report.income, currency)}
                        </td>
                        <td className="tabular px-3 py-3 text-right">
                          {formatMoney(report.expenses, currency)}
                        </td>
                        <td className="tabular px-5 py-3 text-right">
                          {formatMoney(report.net, currency)}
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                  <p className="flex items-center gap-4 px-5 py-3 text-[12px] text-[color:var(--text-subtle)]">
                    <span className="flex items-center gap-1.5">
                      <span className="h-1.5 w-4 rounded-full bg-emerald-500/70" aria-hidden />
                      Income
                    </span>
                    <span className="flex items-center gap-1.5">
                      <span className="h-1.5 w-4 rounded-full bg-ink-400/60" aria-hidden />
                      Expenses
                    </span>
                  </p>
                </div>
              ) : (
                <p className="px-5 pb-6 text-[14px] text-[color:var(--text-muted)]">
                  Nothing was paid or spent in this period.
                </p>
              )}
            </Card>

            <div className="space-y-5">
              {/* ---- Where the money went ---- */}
              <Card padded={false}>
                <div className="px-5 pb-4 pt-5">
                  <SectionTitle title="Expenses by category" />
                </div>
                {report.categories.length ? (
                  <ul className="divide-y">
                    {report.categories.map((row) => (
                      <li key={row.name} className="flex items-center gap-3 px-5 py-2.5">
                        <span className="min-w-0 flex-1 truncate text-[14px]">{row.name}</span>
                        <span className="tabular shrink-0 text-[12px] text-[color:var(--text-subtle)]">
                          {row.count}
                        </span>
                        <span className="tabular w-24 shrink-0 text-right text-[14px] font-medium">
                          {formatMoney(row.total, currency)}
                        </span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="px-5 pb-6 text-[14px] text-[color:var(--text-muted)]">
                    No expenses in this period.
                  </p>
                )}
              </Card>

              {/* ---- Where it came from ---- */}
              <Card padded={false}>
                <div className="px-5 pb-4 pt-5">
                  <SectionTitle title="Income by client" subtitle="Paid documents only." />
                </div>
                {report.clients.length ? (
                  <ul className="divide-y">
                    {report.clients.map((row) => (
                      <li key={row.name} className="flex items-center gap-3 px-5 py-2.5">
                        <span className="min-w-0 flex-1 truncate text-[14px]">{row.name}</span>
                        <span className="tabular shrink-0 text-[12px] text-[color:var(--text-subtle)]">
                          {row.count}
                        </span>
                        <span className="tabular w-24 shrink-0 text-right text-[14px] font-medium">
                          {formatMoney(row.total, currency)}
                        </span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="px-5 pb-6 text-[14px] text-[color:var(--text-muted)]">
                    Nothing was paid in this period.
                  </p>
                )}
              </Card>

              {/* ---- Tax, kept out of the headline numbers ---- */}
              <Card className="space-y-2.5">
                <SectionTitle title="Tax" subtitle="For whoever files your return." />
                <dl className="space-y-1.5 text-[14px]">
                  <div className="flex items-baseline justify-between">
                    <dt className="text-[color:var(--text-muted)]">
                      Collected on documents issued
                    </dt>
                    <dd className="tabular font-medium">
                      {formatMoney(report.taxCollected, currency)}
                    </dd>
                  </div>
                  <div className="flex items-baseline justify-between">
                    <dt className="text-[color:var(--text-muted)]">Paid on expenses</dt>
                    <dd className="tabular font-medium">{formatMoney(report.taxPaid, currency)}</dd>
                  </div>
                  <div className="flex items-baseline justify-between border-t pt-2">
                    <dt className="font-semibold">Difference</dt>
                    <dd className="tabular font-semibold">
                      {formatMoney(report.taxCollected - report.taxPaid, currency)}
                    </dd>
                  </div>
                </dl>
                <p className="text-[12.5px] leading-relaxed text-[color:var(--text-subtle)]">
                  Totals only — SimpleBooks is not tax software and does not know your
                  jurisdiction's rules.
                </p>
              </Card>
            </div>
          </div>

          <p className="mt-6 text-[12.5px] leading-relaxed text-[color:var(--text-subtle)]">
            Income counts a document on the day it was marked paid. “Outstanding now” is every
            unpaid invoice as of today, whenever it was issued — so it does not change with the
            period above.
          </p>
        </>
      )}
    </div>
  )
}
