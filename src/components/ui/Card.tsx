import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

export function Card({
  children,
  className,
  padded = true,
}: {
  children: ReactNode
  className?: string
  padded?: boolean
}) {
  return (
    <div
      className={cn(
        'surface rounded-2xl shadow-card',
        padded && 'p-5',
        className,
      )}
    >
      {children}
    </div>
  )
}

export function SectionTitle({
  title,
  subtitle,
  action,
  className,
}: {
  title: string
  subtitle?: string
  action?: ReactNode
  className?: string
}) {
  return (
    <div className={cn('flex items-end justify-between gap-4', className)}>
      <div>
        <h2 className="text-[17px] font-semibold tracking-[-0.01em]">{title}</h2>
        {subtitle ? (
          <p className="mt-0.5 text-[13.5px] text-[color:var(--text-muted)]">{subtitle}</p>
        ) : null}
      </div>
      {action}
    </div>
  )
}

/** A big number with a label — the whole of our "analytics". */
export function StatCard({
  label,
  value,
  hint,
  icon,
  tone = 'neutral',
}: {
  label: string
  value: string
  hint?: string
  icon?: ReactNode
  tone?: 'neutral' | 'positive' | 'warning' | 'brand'
}) {
  const toneClass = {
    neutral: 'text-[color:var(--text)]',
    positive: 'text-emerald-600 dark:text-emerald-400',
    warning: 'text-amber-600 dark:text-amber-400',
    brand: 'text-[color:var(--brand)]',
  }[tone]

  return (
    <Card className="flex flex-col justify-between gap-4">
      <div className="flex items-start justify-between gap-3">
        <span className="text-[13px] font-medium uppercase tracking-wide text-[color:var(--text-subtle)]">
          {label}
        </span>
        {icon ? <span className="text-[color:var(--text-subtle)]">{icon}</span> : null}
      </div>
      <div>
        <div className={cn('tabular text-[30px] font-semibold leading-none tracking-[-0.02em]', toneClass)}>
          {value}
        </div>
        {hint ? (
          <div className="mt-2 text-[13px] text-[color:var(--text-muted)]">{hint}</div>
        ) : null}
      </div>
    </Card>
  )
}
