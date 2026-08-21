import { useEffect, useRef, useState } from 'react'
import { Building2, Check, ChevronsUpDown, Plus } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useApp } from '../store/useApp'
import { useCompanies } from '../store/useCompanyData'
import { cn } from '../lib/cn'
import { initials } from '../lib/format'
import type { Company } from '../types'

export function CompanyAvatar({
  company,
  size = 36,
  className,
}: {
  company: Company
  size?: number
  className?: string
}) {
  const style = { width: size, height: size, borderRadius: Math.max(8, size * 0.28) }

  if (company.logo) {
    return (
      <img
        src={company.logo}
        alt=""
        style={style}
        className={cn('shrink-0 object-cover', className)}
      />
    )
  }
  return (
    <span
      style={{ ...style, background: company.brandColor }}
      className={cn(
        'flex shrink-0 items-center justify-center font-semibold text-white',
        className,
      )}
      aria-hidden
    >
      <span style={{ fontSize: size * 0.4 }}>{initials(company.name || '?')}</span>
    </span>
  )
}

const TYPE_LABEL = { nonprofit: 'Nonprofit', forprofit: 'For-profit' } as const

/**
 * One click opens the list, a second click switches everything in the app to
 * that company. Nothing else to learn.
 */
export function CompanySwitcher() {
  const companies = useCompanies()
  const activeCompanyId = useApp((s) => s.activeCompanyId)
  const setActiveCompany = useApp((s) => s.setActiveCompany)
  const toast = useApp((s) => s.toast)
  const navigate = useNavigate()

  const [open, setOpen] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (!open) return
    const onPointerDown = (event: MouseEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setOpen(false)
        triggerRef.current?.focus()
        return
      }
      if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
      const options = [
        ...(containerRef.current?.querySelectorAll<HTMLElement>('[role="option"]') ?? []),
      ]
      if (!options.length) return
      event.preventDefault()
      const current = options.indexOf(document.activeElement as HTMLElement)
      const step = event.key === 'ArrowDown' ? 1 : -1
      const next = current === -1 ? (step === 1 ? 0 : options.length - 1) : current + step
      options[(next + options.length) % options.length]?.focus()
    }
    document.addEventListener('mousedown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('mousedown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [open])

  const active = companies?.find((c) => c.id === activeCompanyId)
  if (!companies || !active) return null

  const switchTo = async (company: Company) => {
    setOpen(false)
    if (company.id === activeCompanyId) return
    await setActiveCompany(company.id)
    toast(`Switched to ${company.name}`, 'info')
  }

  return (
    <div ref={containerRef} className="relative min-w-0">
      <button
        ref={triggerRef}
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`Active company: ${active.name}. Switch company`}
        className={cn(
          'flex items-center gap-2.5 rounded-xl py-1.5 pl-1.5 pr-2.5 text-left transition',
          'hover:bg-black/5 dark:hover:bg-white/10',
          open && 'bg-black/5 dark:bg-white/10',
        )}
      >
        <CompanyAvatar company={active} size={34} />
        {/* Kept visible even on a phone — knowing which company you are in
            matters more than the few pixels it costs. */}
        <span className="min-w-0 max-w-[7rem] sm:max-w-[11rem] lg:max-w-none">
          <span className="block truncate text-[14.5px] font-semibold leading-tight tracking-[-0.01em]">
            {active.name}
          </span>
          <span className="block text-[12px] leading-tight text-[color:var(--text-subtle)]">
            {TYPE_LABEL[active.type]} · {active.currency}
          </span>
        </span>
        <ChevronsUpDown className="h-4 w-4 shrink-0 text-[color:var(--text-subtle)]" aria-hidden />
      </button>

      {open ? (
        <div
          role="listbox"
          className="surface absolute left-0 top-[calc(100%+6px)] z-40 w-[19rem] animate-slide-up overflow-hidden rounded-2xl shadow-pop"
        >
          <div className="px-3 pb-1.5 pt-3 text-[11.5px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
            Your companies
          </div>
          <div className="max-h-[19rem] overflow-y-auto px-1.5 pb-1.5">
            {companies.map((company) => (
              <button
                key={company.id}
                role="option"
                aria-selected={company.id === activeCompanyId}
                onClick={() => switchTo(company)}
                className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left transition hover:bg-black/5 dark:hover:bg-white/10"
              >
                <CompanyAvatar company={company} size={32} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-medium leading-tight">
                    {company.name}
                  </span>
                  <span className="block text-[12px] leading-tight text-[color:var(--text-subtle)]">
                    {TYPE_LABEL[company.type]} · {company.currency}
                  </span>
                </span>
                {company.id === activeCompanyId ? (
                  <Check className="h-4 w-4 shrink-0 text-[color:var(--brand)]" aria-hidden />
                ) : null}
              </button>
            ))}
          </div>

          <div className="border-t p-1.5">
            <button
              onClick={() => {
                setOpen(false)
                navigate('/settings?new=company')
              }}
              className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left transition hover:bg-black/5 dark:hover:bg-white/10"
            >
              <span className="flex h-8 w-8 items-center justify-center rounded-lg border border-dashed">
                <Plus className="h-4 w-4" aria-hidden />
              </span>
              <span className="text-[14px] font-medium">Add a company</span>
            </button>
            <button
              onClick={() => {
                setOpen(false)
                navigate('/settings')
              }}
              className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left transition hover:bg-black/5 dark:hover:bg-white/10"
            >
              <span className="flex h-8 w-8 items-center justify-center rounded-lg border">
                <Building2 className="h-4 w-4" aria-hidden />
              </span>
              <span className="text-[14px] font-medium">Manage companies</span>
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}
