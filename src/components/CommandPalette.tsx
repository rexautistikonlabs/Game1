import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useNavigate } from 'react-router-dom'
import {
  Building2,
  ChartNoAxesColumn,
  Check,
  CornerDownLeft,
  Download,
  FileText,
  LayoutDashboard,
  Plus,
  Receipt,
  ScanLine,
  Search,
  Settings as SettingsIcon,
  Users,
  Wallet,
} from 'lucide-react'
import { CompanyAvatar } from './CompanySwitcher'
import { cn } from '../lib/cn'
import { computeTotals, formatDate, formatMoney } from '../lib/format'
import { useApp } from '../store/useApp'
import {
  useClients,
  useCompanies,
  useDocuments,
  useExpenses,
} from '../store/useCompanyData'

interface Command {
  id: string
  group: 'Actions' | 'Switch company' | 'Go to' | 'Invoices & receipts' | 'Clients' | 'Expenses'
  label: string
  hint?: string
  icon: React.ReactNode
  /** Extra text matched against the query but not displayed. */
  keywords?: string
  active?: boolean
  run: () => void
}

/**
 * One keystroke (Cmd/Ctrl+K) to reach anything: switch company, jump to a page,
 * start a new document, or find an invoice, client or expense by name. Keeps
 * the rest of the interface free of navigation chrome.
 */
export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
  const navigate = useNavigate()
  const companies = useCompanies()
  const documents = useDocuments()
  const clients = useClients()
  const expenses = useExpenses()
  const activeCompanyId = useApp((s) => s.activeCompanyId)
  const setActiveCompany = useApp((s) => s.setActiveCompany)
  const toast = useApp((s) => s.toast)

  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  // Focus is returned to whatever opened the palette when it closes.
  const openerRef = useRef<Element | null>(null)

  // Captured during the opening render, before the portal's input takes focus.
  const wasOpen = useRef(false)
  if (open && !wasOpen.current) openerRef.current = document.activeElement
  wasOpen.current = open

  useEffect(() => {
    if (open) {
      setQuery('')
      setSelected(0)
      // The input mounts with the portal, so focus on the next frame.
      requestAnimationFrame(() => inputRef.current?.focus())
    } else if (openerRef.current instanceof HTMLElement && document.body.contains(openerRef.current)) {
      openerRef.current.focus()
    }
  }, [open])

  const commands = useMemo<Command[]>(() => {
    if (!open) return []
    const list: Command[] = [
      {
        id: 'new-invoice',
        group: 'Actions',
        label: 'New invoice',
        hint: 'Bill a client',
        icon: <Plus className="h-4 w-4" />,
        keywords: 'create bill charge',
        run: () => navigate('/invoices/new'),
      },
      {
        id: 'new-receipt',
        group: 'Actions',
        label: 'New receipt',
        hint: 'Record a payment received',
        icon: <Plus className="h-4 w-4" />,
        keywords: 'create donation payment',
        run: () => navigate('/receipts/new'),
      },
      {
        id: 'import-scan',
        group: 'Actions',
        label: 'Import a scanned receipt',
        hint: 'Read a photo or PDF',
        icon: <ScanLine className="h-4 w-4" />,
        keywords: 'ocr expense upload photo',
        run: () => navigate('/expenses?import=1'),
      },
      {
        id: 'new-client',
        group: 'Actions',
        label: 'New client',
        icon: <Plus className="h-4 w-4" />,
        keywords: 'customer add',
        run: () => navigate('/clients?new=1'),
      },
      {
        id: 'add-company',
        group: 'Actions',
        label: 'Add a company',
        icon: <Building2 className="h-4 w-4" />,
        keywords: 'organisation organization business new',
        run: () => navigate('/settings?new=company'),
      },
      {
        id: 'backup',
        group: 'Actions',
        label: 'Export a backup',
        hint: 'Everything, as JSON',
        icon: <Download className="h-4 w-4" />,
        keywords: 'save json download data',
        run: () => navigate('/settings?backup=1'),
      },
    ]

    for (const company of companies ?? []) {
      list.push({
        id: `company-${company.id}`,
        group: 'Switch company',
        label: company.name,
        hint: company.type === 'nonprofit' ? 'Nonprofit' : 'For-profit',
        icon: <CompanyAvatar company={company} size={20} />,
        keywords: `${company.legalName ?? ''} ${company.currency}`,
        active: company.id === activeCompanyId,
        run: async () => {
          if (company.id === activeCompanyId) return
          await setActiveCompany(company.id)
          toast(`Switched to ${company.name}`, 'info')
        },
      })
    }

    const pages: [string, string, React.ReactNode][] = [
      ['/', 'Dashboard', <LayoutDashboard className="h-4 w-4" />],
      ['/invoices', 'Invoices', <FileText className="h-4 w-4" />],
      ['/receipts', 'Receipts', <Receipt className="h-4 w-4" />],
      ['/expenses', 'Expenses', <Wallet className="h-4 w-4" />],
      ['/reports', 'Reports', <ChartNoAxesColumn className="h-4 w-4" />],
      ['/clients', 'Clients', <Users className="h-4 w-4" />],
      ['/settings', 'Settings', <SettingsIcon className="h-4 w-4" />],
    ]
    for (const [to, label, icon] of pages) {
      list.push({
        id: `go-${to}`,
        group: 'Go to',
        label,
        icon,
        run: () => navigate(to),
      })
    }

    // Records are only worth listing once there is something to match on —
    // otherwise the palette opens as a wall of every invoice you own.
    if (query.trim().length >= 2) {
      for (const doc of documents ?? []) {
        list.push({
          id: `doc-${doc.id}`,
          group: 'Invoices & receipts',
          label: `${doc.number} · ${doc.client.name}`,
          hint: `${formatDate(doc.issueDate)} · ${formatMoney(computeTotals(doc).total, doc.currency)}`,
          icon: doc.kind === 'invoice' ? <FileText className="h-4 w-4" /> : <Receipt className="h-4 w-4" />,
          keywords: `${doc.kind} ${doc.notes ?? ''} ${doc.items.map((i) => i.description).join(' ')}`,
          run: () => navigate(`/documents/${doc.id}`),
        })
      }
      for (const client of clients ?? []) {
        list.push({
          id: `client-${client.id}`,
          group: 'Clients',
          label: client.name,
          hint: client.email,
          icon: <Users className="h-4 w-4" />,
          keywords: client.addressLines.join(' '),
          run: () => navigate(`/invoices/new?client=${client.id}`),
        })
      }
      for (const expense of expenses ?? []) {
        list.push({
          id: `expense-${expense.id}`,
          group: 'Expenses',
          label: expense.vendor,
          hint: `${formatDate(expense.date)} · ${formatMoney(expense.total, expense.currency)} · ${expense.category}`,
          icon: <Wallet className="h-4 w-4" />,
          keywords: `${expense.category} ${expense.notes ?? ''}`,
          run: () => navigate('/expenses'),
        })
      }
    }

    return list
  }, [
    open,
    query,
    companies,
    documents,
    clients,
    expenses,
    activeCompanyId,
    navigate,
    setActiveCompany,
    toast,
  ])

  const results = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return commands.filter((c) => c.group !== 'Invoices & receipts')
    const terms = needle.split(/\s+/)
    return commands
      .filter((command) => {
        const haystack = `${command.label} ${command.hint ?? ''} ${command.keywords ?? ''} ${command.group}`.toLowerCase()
        return terms.every((term) => haystack.includes(term))
      })
      .slice(0, 40)
  }, [commands, query])

  // Keep the highlight inside the list as it shrinks while you type.
  useEffect(() => setSelected(0), [query])

  useEffect(() => {
    if (!open) return
    const onKeyDown = (event: KeyboardEvent) => {
      const claim = () => {
        event.preventDefault()
        event.stopPropagation()
      }
      switch (event.key) {
        case 'Escape':
          claim()
          onClose()
          return
        case 'ArrowDown':
          claim()
          setSelected((current) => (results.length ? (current + 1) % results.length : 0))
          return
        case 'ArrowUp':
          claim()
          setSelected((current) =>
            results.length ? (current - 1 + results.length) % results.length : 0,
          )
          return
        case 'Home':
          claim()
          setSelected(0)
          return
        case 'End':
          claim()
          setSelected(Math.max(0, results.length - 1))
          return
        case 'Enter': {
          claim()
          const command = results[selected]
          if (!command) return
          onClose()
          void command.run()
          return
        }
        default:
          return
      }
    }
    // Capture phase, so these beat the app-wide shortcut handler on `document`.
    document.addEventListener('keydown', onKeyDown, true)
    return () => document.removeEventListener('keydown', onKeyDown, true)
  }, [open, results, selected, onClose])

  // Scroll the highlighted row into view when moving by keyboard.
  useEffect(() => {
    listRef.current
      ?.querySelector('[data-selected="true"]')
      ?.scrollIntoView({ block: 'nearest' })
  }, [selected])

  if (!open) return null

  let lastGroup = ''

  return createPortal(
    <div className="no-print fixed inset-0 z-[70] flex items-start justify-center p-4 sm:pt-[12vh]">
      <div
        className="fixed inset-0 animate-fade-in bg-ink-950/40 backdrop-blur-[2px]"
        onClick={onClose}
        aria-hidden
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        className="surface relative flex max-h-[70vh] w-full max-w-xl animate-slide-up flex-col overflow-hidden rounded-2xl shadow-pop"
      >
        <div className="flex items-center gap-3 border-b px-4">
          <Search className="h-4 w-4 shrink-0 text-[color:var(--text-subtle)]" aria-hidden />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search or jump to…"
            aria-label="Search commands, companies and records"
            aria-controls="command-results"
            aria-activedescendant={results[selected] ? `command-${results[selected].id}` : undefined}
            role="combobox"
            aria-expanded="true"
            autoComplete="off"
            spellCheck={false}
            className="h-14 flex-1 bg-transparent text-[16px] outline-none placeholder:text-[color:var(--text-subtle)]"
          />
          <kbd className="hidden shrink-0 rounded border px-1.5 py-0.5 text-[11px] text-[color:var(--text-subtle)] sm:block">
            Esc
          </kbd>
        </div>

        <div ref={listRef} id="command-results" role="listbox" className="flex-1 overflow-y-auto p-2">
          {results.length === 0 ? (
            <p className="px-3 py-8 text-center text-[14px] text-[color:var(--text-muted)]">
              Nothing matches “{query.trim()}”.
            </p>
          ) : (
            results.map((command, index) => {
              const showGroup = command.group !== lastGroup
              lastGroup = command.group
              const isSelected = index === selected
              return (
                <div key={command.id}>
                  {showGroup ? (
                    <div className="px-3 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
                      {command.group}
                    </div>
                  ) : null}
                  <button
                    id={`command-${command.id}`}
                    role="option"
                    aria-selected={isSelected}
                    data-selected={isSelected}
                    onMouseMove={() => setSelected(index)}
                    onClick={() => {
                      onClose()
                      void command.run()
                    }}
                    className={cn(
                      'flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left transition',
                      isSelected ? 'bg-black/[0.055] dark:bg-white/[0.09]' : '',
                    )}
                  >
                    <span className="flex h-5 w-5 shrink-0 items-center justify-center text-[color:var(--text-subtle)]">
                      {command.icon}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[14.5px] font-medium">{command.label}</span>
                      {command.hint ? (
                        <span className="block truncate text-[12.5px] text-[color:var(--text-muted)]">
                          {command.hint}
                        </span>
                      ) : null}
                    </span>
                    {command.active ? (
                      <Check className="h-4 w-4 shrink-0 text-[color:var(--brand)]" aria-hidden />
                    ) : isSelected ? (
                      <CornerDownLeft
                        className="h-3.5 w-3.5 shrink-0 text-[color:var(--text-subtle)]"
                        aria-hidden
                      />
                    ) : null}
                  </button>
                </div>
              )
            })
          )}
        </div>

        <div className="flex items-center gap-4 border-t px-4 py-2.5 text-[11.5px] text-[color:var(--text-subtle)]">
          <span className="flex items-center gap-1.5">
            <kbd className="rounded border px-1 py-0.5">↑</kbd>
            <kbd className="rounded border px-1 py-0.5">↓</kbd>
            to move
          </span>
          <span className="flex items-center gap-1.5">
            <kbd className="rounded border px-1 py-0.5">↵</kbd>
            to select
          </span>
          <span className="ml-auto hidden sm:block">
            <kbd className="rounded border px-1 py-0.5">⌘</kbd>
            <kbd className="ml-1 rounded border px-1 py-0.5">K</kbd> anywhere
          </span>
        </div>
      </div>
    </div>,
    document.body,
  )
}
