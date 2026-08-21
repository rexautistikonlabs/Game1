import { Command, Sparkles, X } from 'lucide-react'
import { Link } from 'react-router-dom'
import { IconButton } from './ui/Button'
import { setSetting } from '../db/db'
import { SAMPLE_TIP_FLAG } from '../db/seed'
import { shortcutLabel } from '../lib/shortcuts'
import { useSetting } from '../store/useCompanyData'

/**
 * Shown once, on the dashboard, while the two example companies are still the
 * only thing in the database. It answers the three questions a first-time user
 * actually has: what is this data, how do I switch company, and how do I get
 * rid of it.
 */
export function SampleDataTip() {
  const show = useSetting<boolean>(SAMPLE_TIP_FLAG, false)
  if (!show) return null

  return (
    <div
      className="surface relative mb-6 flex items-start gap-4 rounded-2xl p-5 shadow-card"
      style={{ borderColor: 'var(--brand)' }}
    >
      <span
        className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl"
        style={{ background: 'var(--brand-soft)', color: 'var(--brand)' }}
        aria-hidden
      >
        <Sparkles className="h-5 w-5" />
      </span>

      <div className="min-w-0 flex-1">
        <h2 className="text-[15.5px] font-semibold tracking-[-0.01em]">
          You are looking at sample data
        </h2>
        <p className="mt-1 text-[14px] leading-relaxed text-[color:var(--text-muted)]">
          SimpleBooks starts with two example companies — a nonprofit and an LLC — so you can
          see how everything fits together. They are completely separate sets of books.
        </p>
        <ul className="mt-3 space-y-1.5 text-[13.5px] text-[color:var(--text-muted)]">
          <li>
            <span className="font-medium text-[color:var(--text)]">Switch company</span> from the
            name in the top-left corner — every page follows along.
          </li>
          <li className="flex items-center gap-1.5">
            <Command className="h-3.5 w-3.5 shrink-0" aria-hidden />
            <span>
              Press{' '}
              <kbd className="rounded border px-1.5 py-px font-sans text-[12px]">
                {shortcutLabel({ key: 'k', mod: true })}
              </kbd>{' '}
              to jump to anything, or{' '}
              <kbd className="rounded border px-1.5 py-px font-sans text-[12px]">?</kbd> for all
              shortcuts.
            </span>
          </li>
          <li>
            Ready for real books?{' '}
            <Link
              to="/settings?new=company"
              className="font-medium text-[color:var(--brand)] hover:underline"
            >
              Add your own company
            </Link>
            , then delete the examples from{' '}
            <Link to="/settings" className="font-medium text-[color:var(--brand)] hover:underline">
              Settings
            </Link>
            .
          </li>
        </ul>
      </div>

      <IconButton
        variant="ghost"
        size="sm"
        aria-label="Dismiss this tip"
        title="Dismiss"
        onClick={() => void setSetting(SAMPLE_TIP_FLAG, false)}
        className="shrink-0 text-[color:var(--text-subtle)]"
      >
        <X className="h-4 w-4" />
      </IconButton>
    </div>
  )
}
