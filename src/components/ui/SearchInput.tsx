import { Search, X } from 'lucide-react'
import { cn } from '../../lib/cn'

export function SearchInput({
  value,
  onChange,
  placeholder = 'Search…',
  className,
}: {
  value: string
  onChange: (value: string) => void
  placeholder?: string
  className?: string
}) {
  return (
    <div className={cn('relative', className)}>
      <Search
        className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[color:var(--text-subtle)]"
        aria-hidden
      />
      <input
        type="search"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        aria-label={placeholder}
        className="field pl-9 pr-9 [&::-webkit-search-cancel-button]:hidden"
      />
      {value ? (
        <button
          onClick={() => onChange('')}
          className="absolute right-2.5 top-1/2 -translate-y-1/2 rounded p-1 text-[color:var(--text-subtle)] transition hover:text-[color:var(--text)]"
          aria-label="Clear search"
        >
          <X className="h-3.5 w-3.5" />
        </button>
      ) : null}
    </div>
  )
}

/** Segmented control — used for status filters and the invoice/receipt toggle. */
export function Segmented<T extends string>({
  value,
  onChange,
  options,
  className,
  size = 'md',
}: {
  value: T
  onChange: (value: T) => void
  options: { value: T; label: string; count?: number }[]
  className?: string
  size?: 'sm' | 'md'
}) {
  return (
    <div
      className={cn(
        // `max-w-full` + horizontal scroll so a long set of filters never
        // widens the page on a small phone.
        'inline-flex max-w-full items-center gap-1 overflow-x-auto rounded-xl p-1',
        'bg-ink-100/80 dark:bg-white/[0.06]',
        className,
      )}
      role="tablist"
    >
      {options.map((option) => {
        const active = option.value === value
        return (
          <button
            key={option.value}
            role="tab"
            aria-selected={active}
            onClick={() => onChange(option.value)}
            className={cn(
              'shrink-0 rounded-lg font-medium transition',
              size === 'sm' ? 'px-3 py-1.5 text-[13px]' : 'px-3.5 py-2 text-[14px]',
              active
                ? 'bg-[color:var(--surface)] shadow-card'
                : 'text-[color:var(--text-muted)] hover:text-[color:var(--text)]',
            )}
          >
            {option.label}
            {option.count !== undefined ? (
              <span
                className={cn(
                  'tabular ml-1.5 text-[12px]',
                  active ? 'text-[color:var(--text-subtle)]' : 'opacity-70',
                )}
              >
                {option.count}
              </span>
            ) : null}
          </button>
        )
      })}
    </div>
  )
}
