import { useEffect, useId, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { X } from 'lucide-react'
import { cn } from '../../lib/cn'
import { IconButton } from './Button'

export interface ModalProps {
  open: boolean
  onClose: () => void
  title: string
  description?: string
  children: ReactNode
  footer?: ReactNode
  size?: 'sm' | 'md' | 'lg' | 'xl'
}

const SIZES = {
  sm: 'max-w-md',
  md: 'max-w-xl',
  lg: 'max-w-3xl',
  xl: 'max-w-5xl',
}

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export function Modal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  size = 'md',
}: ModalProps) {
  const dialogRef = useRef<HTMLDivElement>(null)
  // Whatever was focused when the dialog opened, so it can be given focus back.
  const openerRef = useRef<Element | null>(null)
  const titleId = useId()
  const descriptionId = useId()

  // Callers pass an inline arrow for `onClose`, which would make it a new value
  // on every render. Reading it through a ref keeps the effect below keyed on
  // `open` alone — otherwise it tears down and re-runs constantly, stealing
  // focus back to the opener while you are still typing in the dialog.
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose

  // Capture the opener during the render that opens the dialog, not in the
  // effect below. A field marked `autoFocus` is focused during commit — before
  // effects run — so capturing later records the dialog's own first input as
  // the "opener", and closing then restores focus to a detached node.
  const wasOpen = useRef(false)
  if (open && !wasOpen.current) openerRef.current = document.activeElement
  wasOpen.current = open

  useEffect(() => {
    if (!open) return

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        onCloseRef.current()
        return
      }
      // Tab cycles within the dialog: focus must not escape to the page behind.
      if (event.key !== 'Tab') return
      const dialog = dialogRef.current
      if (!dialog) return
      const focusable = [...dialog.querySelectorAll<HTMLElement>(FOCUSABLE)].filter(
        (element) => element.offsetParent !== null,
      )
      if (focusable.length === 0) {
        event.preventDefault()
        return
      }
      const first = focusable[0]!
      const last = focusable[focusable.length - 1]!
      const active = document.activeElement
      if (event.shiftKey && (active === first || !dialog.contains(active))) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && active === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', onKeyDown)
    // Stop the page behind the dialog from scrolling.
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    // Focus the first field rather than the close button, so a dialog that
    // exists to be filled in is ready to type into. `autoFocus` on a field
    // wins, because React applies it before this runs.
    const frame = requestAnimationFrame(() => {
      const dialog = dialogRef.current
      if (!dialog || dialog.contains(document.activeElement)) return
      const target =
        dialog.querySelector<HTMLElement>('[autofocus]') ??
        dialog.querySelector<HTMLElement>('input:not([type="hidden"]), textarea, select') ??
        dialog.querySelector<HTMLElement>(FOCUSABLE)
      target?.focus()
    })

    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
      cancelAnimationFrame(frame)
      // Returning focus is what makes a dialog usable by keyboard twice.
      if (openerRef.current instanceof HTMLElement && document.body.contains(openerRef.current)) {
        openerRef.current.focus()
      }
    }
  }, [open])

  if (!open) return null

  return createPortal(
    <div className="no-print fixed inset-0 z-50 flex items-start justify-center overflow-y-auto p-4 sm:p-8">
      <div
        className="fixed inset-0 animate-fade-in bg-ink-950/40 backdrop-blur-[2px]"
        onClick={onClose}
        aria-hidden
      />
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
        className={cn(
          'surface relative my-auto w-full animate-slide-up rounded-2xl shadow-pop',
          SIZES[size],
        )}
      >
        <div className="flex items-start justify-between gap-4 border-b px-6 py-5">
          <div>
            <h2 id={titleId} className="text-[19px] font-semibold tracking-[-0.01em]">
              {title}
            </h2>
            {description ? (
              <p id={descriptionId} className="mt-1 text-[14px] text-[color:var(--text-muted)]">
                {description}
              </p>
            ) : null}
          </div>
          <IconButton variant="ghost" size="sm" onClick={onClose} aria-label="Close">
            <X className="h-4.5 w-4.5" />
          </IconButton>
        </div>

        <div className="px-6 py-5">{children}</div>

        {footer ? (
          <div className="flex items-center justify-end gap-2.5 border-t px-6 py-4">{footer}</div>
        ) : null}
      </div>
    </div>,
    document.body,
  )
}
