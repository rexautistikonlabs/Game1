import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'
import type { DisplayStatus } from '../../lib/format'

const STATUS_STYLES: Record<DisplayStatus, string> = {
  draft: 'bg-ink-100 text-ink-600 dark:bg-white/10 dark:text-ink-200',
  sent: 'bg-blue-50 text-blue-700 dark:bg-blue-500/15 dark:text-blue-300',
  paid: 'bg-emerald-50 text-emerald-700 dark:bg-emerald-500/15 dark:text-emerald-300',
  overdue: 'bg-red-50 text-red-700 dark:bg-red-500/15 dark:text-red-300',
}

const STATUS_LABELS: Record<DisplayStatus, string> = {
  draft: 'Draft',
  sent: 'Sent',
  paid: 'Paid',
  overdue: 'Overdue',
}

export function StatusBadge({ status, className }: { status: DisplayStatus; className?: string }) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-full px-2.5 py-1 text-[12px] font-semibold',
        STATUS_STYLES[status],
        className,
      )}
    >
      {STATUS_LABELS[status]}
    </span>
  )
}

export function Chip({
  children,
  className,
  tone = 'neutral',
}: {
  children: ReactNode
  className?: string
  tone?: 'neutral' | 'brand'
}) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-medium',
        tone === 'brand'
          ? 'text-[color:var(--brand)]'
          : 'bg-ink-100 text-ink-600 dark:bg-white/10 dark:text-ink-200',
        className,
      )}
      style={tone === 'brand' ? { background: 'var(--brand-soft)' } : undefined}
    >
      {children}
    </span>
  )
}
