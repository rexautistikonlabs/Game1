import { useMemo, useState } from 'react'
import { Download } from 'lucide-react'
import { Button } from './ui/Button'
import { Field, Input, Select } from './ui/Input'
import { Modal } from './ui/Modal'
import { Segmented } from './ui/SearchInput'
import {
  documentLinesToCsv,
  documentsToCsv,
  exportFilename,
  expensesToCsv,
} from '../lib/csv'
import { saveFile } from '../lib/download'
import { monthStart, today, yearStart } from '../lib/format'
import { useApp } from '../store/useApp'
import type { Company, Document, Expense } from '../types'

export type ExportWhat = 'invoices' | 'receipts' | 'expenses'

const RANGE_PRESETS = [
  { value: 'month', label: 'This month' },
  { value: 'year', label: 'This year' },
  { value: 'all', label: 'Everything' },
  { value: 'custom', label: 'Custom' },
] as const

type RangePreset = (typeof RANGE_PRESETS)[number]['value']

/**
 * Pick what, pick a date range, get a CSV. Always scoped to the company you
 * are looking at — cross-company exports would be a bookkeeping hazard.
 */
export function ExportDialog({
  open,
  onClose,
  company,
  documents,
  expenses,
  initialWhat = 'invoices',
}: {
  open: boolean
  onClose: () => void
  company: Company
  documents: Document[]
  expenses: Expense[]
  initialWhat?: ExportWhat
}) {
  const toast = useApp((s) => s.toast)
  const [what, setWhat] = useState<ExportWhat>(initialWhat)
  const [preset, setPreset] = useState<RangePreset>('year')
  const [from, setFrom] = useState(yearStart())
  const [to, setTo] = useState(today())
  const [detail, setDetail] = useState<'summary' | 'lines'>('summary')
  const [busy, setBusy] = useState(false)

  const range = useMemo(() => {
    if (preset === 'month') return { from: monthStart(), to: today() }
    if (preset === 'year') return { from: yearStart(), to: today() }
    if (preset === 'all') return { from: '0000-01-01', to: '9999-12-31' }
    return { from, to }
  }, [preset, from, to])

  const matching = useMemo(() => {
    if (what === 'expenses') {
      return expenses.filter((e) => e.date >= range.from && e.date <= range.to)
    }
    const kind = what === 'invoices' ? 'invoice' : 'receipt'
    return documents.filter(
      (d) => d.kind === kind && d.issueDate >= range.from && d.issueDate <= range.to,
    )
  }, [what, documents, expenses, range])

  const rangeLabel =
    preset === 'all' ? 'all-time' : `${range.from} to ${range.to}`

  const download = async () => {
    if (matching.length === 0) {
      toast('Nothing to export in that date range.', 'error')
      return
    }
    setBusy(true)
    try {
      const csv =
        what === 'expenses'
          ? expensesToCsv(matching as Expense[])
          : detail === 'lines'
            ? documentLinesToCsv(matching as Document[])
            : documentsToCsv(matching as Document[])

      const filename = exportFilename(
        company,
        what,
        preset === 'all' ? 'all' : range.from,
        preset === 'all' ? 'time' : range.to,
      )
      const saved = await saveFile(filename, csv, 'text/csv;charset=utf-8')
      if (saved) {
        toast(`Exported ${matching.length} ${matching.length === 1 ? 'row' : 'rows'} to CSV`)
        onClose()
      }
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Export failed.', 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Export to CSV"
      description={`${company.name} only — ready for your spreadsheet or bookkeeper.`}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="brand" onClick={download} loading={busy} disabled={matching.length === 0}>
            <Download className="h-4 w-4" aria-hidden />
            Export {matching.length} {matching.length === 1 ? 'row' : 'rows'}
          </Button>
        </>
      }
    >
      <div className="space-y-5">
        <Field label="What to export">
          <Segmented
            value={what}
            onChange={setWhat}
            options={[
              { value: 'invoices', label: 'Invoices' },
              { value: 'receipts', label: 'Receipts' },
              { value: 'expenses', label: 'Expenses' },
            ]}
          />
        </Field>

        <Field label="Date range">
          <Select value={preset} onChange={(event) => setPreset(event.target.value as RangePreset)}>
            {RANGE_PRESETS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </Field>

        {preset === 'custom' ? (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="From">
              <Input type="date" value={from} onChange={(event) => setFrom(event.target.value)} />
            </Field>
            <Field label="To">
              <Input type="date" value={to} onChange={(event) => setTo(event.target.value)} />
            </Field>
          </div>
        ) : null}

        {what !== 'expenses' ? (
          <Field
            label="Level of detail"
            hint={
              detail === 'summary'
                ? 'One row per document, with subtotal, tax and total.'
                : 'One row per line item — better for revenue breakdowns.'
            }
          >
            <Segmented
              value={detail}
              onChange={setDetail}
              size="sm"
              options={[
                { value: 'summary', label: 'One row per document' },
                { value: 'lines', label: 'One row per line item' },
              ]}
            />
          </Field>
        ) : null}

        <div className="rounded-xl border px-4 py-3 text-[13.5px] text-[color:var(--text-muted)]">
          <span className="font-medium text-[color:var(--text)]">{matching.length}</span>{' '}
          {what} for <span className="font-medium text-[color:var(--text)]">{company.name}</span>,{' '}
          {rangeLabel}.
        </div>
      </div>
    </Modal>
  )
}
