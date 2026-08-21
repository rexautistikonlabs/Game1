import { forwardRef, type ButtonHTMLAttributes } from 'react'
import { Loader2 } from 'lucide-react'
import { cn } from '../../lib/cn'

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'brand'
type Size = 'sm' | 'md' | 'lg'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant
  size?: Size
  loading?: boolean
  /** Full-width block button — used in empty states and dialogs. */
  block?: boolean
}

const VARIANTS: Record<Variant, string> = {
  primary:
    'bg-ink-900 text-white hover:bg-ink-800 active:bg-ink-950 shadow-card dark:bg-white dark:text-ink-900 dark:hover:bg-ink-100',
  brand: 'text-[color:var(--brand-ink)] shadow-card hover:brightness-95 active:brightness-90',
  secondary: 'border hover:border-[color:var(--text-subtle)]',
  ghost: 'hover:bg-black/5 dark:hover:bg-white/10',
  danger: 'bg-red-600 text-white hover:bg-red-700 active:bg-red-800 shadow-card',
}

const SIZES: Record<Size, string> = {
  sm: 'h-8 px-3 text-[13px] gap-1.5 rounded-lg',
  md: 'h-10 px-4 text-[14px] gap-2 rounded-lg',
  lg: 'h-12 px-6 text-[15px] gap-2.5 rounded-xl',
}

/**
 * Buttons are big and obvious on purpose — the whole app is meant to be usable
 * without hunting for the control you need.
 */
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'secondary', size = 'md', loading, block, className, children, disabled, style, ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      disabled={disabled || loading}
      style={
        variant === 'brand' ? { background: 'var(--brand)', ...style } : style
      }
      className={cn(
        'inline-flex select-none items-center justify-center whitespace-nowrap font-medium transition',
        'disabled:pointer-events-none disabled:opacity-50',
        VARIANTS[variant],
        SIZES[size],
        variant === 'secondary' && 'bg-[color:var(--surface)]',
        block && 'w-full',
        className,
      )}
      {...rest}
    >
      {loading ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : null}
      {children}
    </button>
  )
})

/** Square icon-only button. Always pass an aria-label. */
export const IconButton = forwardRef<HTMLButtonElement, ButtonProps>(function IconButton(
  { className, size = 'md', ...rest },
  ref,
) {
  return (
    <Button
      ref={ref}
      size={size}
      className={cn('!px-0', size === 'sm' ? 'w-8' : size === 'lg' ? 'w-12' : 'w-10', className)}
      {...rest}
    />
  )
})
