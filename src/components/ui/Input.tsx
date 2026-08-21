import {
  forwardRef,
  type InputHTMLAttributes,
  type ReactNode,
  type SelectHTMLAttributes,
  type TextareaHTMLAttributes,
} from 'react'
import { ChevronDown } from 'lucide-react'
import { cn } from '../../lib/cn'

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(
  function Input({ className, ...rest }, ref) {
    return <input ref={ref} className={cn('field', className)} {...rest} />
  },
)

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(
  function Textarea({ className, rows = 3, ...rest }, ref) {
    return <textarea ref={ref} rows={rows} className={cn('field resize-y', className)} {...rest} />
  },
)

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(
  function Select({ className, children, ...rest }, ref) {
    return (
      <div className="relative">
        <select ref={ref} className={cn('field appearance-none pr-9', className)} {...rest}>
          {children}
        </select>
        <ChevronDown
          className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[color:var(--text-subtle)]"
          aria-hidden
        />
      </div>
    )
  },
)

/** Amount input with the currency symbol shown inside the field. */
export const MoneyInput = forwardRef<
  HTMLInputElement,
  InputHTMLAttributes<HTMLInputElement> & { symbol: string }
>(function MoneyInput({ symbol, className, ...rest }, ref) {
  return (
    <div className="relative">
      <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[14px] text-[color:var(--text-subtle)]">
        {symbol}
      </span>
      <input
        ref={ref}
        type="number"
        step="0.01"
        inputMode="decimal"
        className={cn('field tabular text-right', symbol.length > 1 ? 'pl-12' : 'pl-8', className)}
        {...rest}
      />
    </div>
  )
})

interface FieldProps {
  label: string
  hint?: string
  error?: string
  /** Marks the field visually as required. */
  required?: boolean
  children: ReactNode
  className?: string
}

export function Field({ label, hint, error, required, children, className }: FieldProps) {
  return (
    <label className={cn('block', className)}>
      <span className="label">
        {label}
        {required ? <span className="ml-0.5 text-red-500">*</span> : null}
      </span>
      {children}
      {error ? (
        <span className="mt-1.5 block text-[13px] font-medium text-red-600 dark:text-red-400">
          {error}
        </span>
      ) : hint ? (
        <span className="mt-1.5 block text-[13px] text-[color:var(--text-subtle)]">{hint}</span>
      ) : null}
    </label>
  )
}
