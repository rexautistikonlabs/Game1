import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

export interface EmptyStateProps {
  illustration: ReactNode
  title: string
  description: string
  action?: ReactNode
  secondaryAction?: ReactNode
  className?: string
}

/**
 * Empty states are a feature, not an apology: an illustration, one sentence of
 * plain English, and the single button that fills the space.
 */
export function EmptyState({
  illustration,
  title,
  description,
  action,
  secondaryAction,
  className,
}: EmptyStateProps) {
  return (
    <div
      className={cn(
        'flex flex-col items-center justify-center px-6 py-16 text-center',
        className,
      )}
    >
      <div className="mb-6">{illustration}</div>
      <h3 className="text-[20px] font-semibold tracking-[-0.01em]">{title}</h3>
      <p className="mt-2 max-w-md text-[15px] leading-relaxed text-[color:var(--text-muted)]">
        {description}
      </p>
      {action || secondaryAction ? (
        <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
          {action}
          {secondaryAction}
        </div>
      ) : null}
    </div>
  )
}
