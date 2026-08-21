import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react'
import { useApp } from '../../store/useApp'
import { cn } from '../../lib/cn'

const ICONS = {
  success: CheckCircle2,
  error: AlertCircle,
  info: Info,
}

const TONES = {
  success: 'text-emerald-600 dark:text-emerald-400',
  error: 'text-red-600 dark:text-red-400',
  info: 'text-blue-600 dark:text-blue-400',
}

export function Toaster() {
  const toasts = useApp((s) => s.toasts)
  const dismiss = useApp((s) => s.dismissToast)

  return (
    <div
      className="no-print pointer-events-none fixed bottom-6 left-1/2 z-[60] flex w-full max-w-md -translate-x-1/2 flex-col items-center gap-2 px-4"
      role="status"
      aria-live="polite"
    >
      {toasts.map((toast) => {
        const Icon = ICONS[toast.tone]
        return (
          <div
            key={toast.id}
            className="surface pointer-events-auto flex w-full animate-slide-up items-start gap-3 rounded-xl px-4 py-3 shadow-pop"
          >
            <Icon className={cn('mt-0.5 h-5 w-5 shrink-0', TONES[toast.tone])} aria-hidden />
            <p className="flex-1 text-[14px] leading-snug">{toast.message}</p>
            <button
              onClick={() => dismiss(toast.id)}
              className="-mr-1 shrink-0 rounded p-1 text-[color:var(--text-subtle)] transition hover:text-[color:var(--text)]"
              aria-label="Dismiss"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        )
      })}
    </div>
  )
}
