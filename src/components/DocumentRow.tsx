import { Link } from 'react-router-dom'
import { ChevronRight } from 'lucide-react'
import { StatusBadge } from './ui/Badge'
import { computeTotals, displayStatus, formatDate, formatMoney, daysOverdue } from '../lib/format'
import { cn } from '../lib/cn'
import type { Document } from '../types'

/** One line in a list of invoices or receipts. The whole row is the link. */
export function DocumentRow({ doc, showKind = false }: { doc: Document; showKind?: boolean }) {
  const totals = computeTotals(doc)
  const status = displayStatus(doc)
  const overdueBy = daysOverdue(doc)

  return (
    <Link
      to={`/documents/${doc.id}`}
      className={cn(
        'group flex items-center gap-4 px-4 py-3.5 transition',
        'hover:bg-black/[0.025] dark:hover:bg-white/[0.04]',
      )}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="tabular truncate text-[14.5px] font-semibold">{doc.number}</span>
          {showKind ? (
            <span className="shrink-0 text-[12px] uppercase tracking-wide text-[color:var(--text-subtle)]">
              {doc.kind}
            </span>
          ) : null}
        </div>
        <div className="mt-0.5 truncate text-[13.5px] text-[color:var(--text-muted)]">
          {doc.client.name || 'No client yet'}
        </div>
      </div>

      <div className="hidden w-28 shrink-0 text-[13.5px] text-[color:var(--text-muted)] sm:block">
        {formatDate(doc.issueDate)}
      </div>

      <div className="hidden w-24 shrink-0 md:block">
        <StatusBadge status={status} />
        {overdueBy > 0 ? (
          <div className="mt-1 text-[11.5px] text-red-600 dark:text-red-400">
            {overdueBy} {overdueBy === 1 ? 'day' : 'days'}
          </div>
        ) : null}
      </div>

      <div className="tabular w-28 shrink-0 text-right text-[15px] font-semibold">
        {formatMoney(totals.total, doc.currency)}
      </div>

      <ChevronRight
        className="h-4 w-4 shrink-0 text-[color:var(--text-subtle)] transition group-hover:translate-x-0.5"
        aria-hidden
      />
    </Link>
  )
}

/** Header row that lines up with DocumentRow's columns. */
export function DocumentRowHeader({ showKind = false }: { showKind?: boolean }) {
  void showKind
  return (
    <div className="flex items-center gap-4 border-b px-4 py-2.5 text-[11.5px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
      <div className="min-w-0 flex-1">Number / Client</div>
      <div className="hidden w-28 shrink-0 sm:block">Date</div>
      <div className="hidden w-24 shrink-0 md:block">Status</div>
      <div className="w-28 shrink-0 text-right">Total</div>
      <div className="w-4 shrink-0" />
    </div>
  )
}
