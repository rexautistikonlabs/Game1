import { useEffect, useMemo, useRef, useState } from 'react'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { CommandPalette } from './components/CommandPalette'
import { ShortcutsDialog } from './components/ShortcutsDialog'
import { TopBar } from './components/TopBar'
import { Toaster } from './components/ui/Toaster'
import { Dashboard } from './pages/Dashboard'
import { DocumentEdit } from './pages/DocumentEdit'
import { DocumentView } from './pages/DocumentView'
import { Documents } from './pages/Documents'
import { Expenses } from './pages/Expenses'
import { Reports } from './pages/Reports'
import { Clients } from './pages/Clients'
import { Settings } from './pages/Settings'
import { Welcome } from './pages/Welcome'
import { useApp } from './store/useApp'
import { useActiveCompany, useCompanies } from './store/useCompanyData'
import { onDesktopMenu } from './lib/download'
import { confirmNavigation } from './lib/navGuard'
import { catchUpRecurring } from './lib/recurrence'
import { useShortcuts, type Shortcut } from './lib/shortcuts'
import { withAlpha, readableOn } from './lib/format'
import type { DocumentKind } from './types'

/** Paints the whole app in the active company's colour. */
function useBrandTheme() {
  const company = useActiveCompany()
  useEffect(() => {
    const brand = company?.brandColor || '#1d4ed8'
    const root = document.documentElement
    root.style.setProperty('--brand', brand)
    root.style.setProperty('--brand-soft', withAlpha(brand, 0.1))
    root.style.setProperty('--brand-ink', readableOn(brand))
  }, [company?.brandColor])
}

/** Wires the Electron application menu to in-app navigation. */
function useDesktopMenu(handlers: {
  openPalette: () => void
  openShortcuts: () => void
}) {
  const navigate = useNavigate()
  // Read through a ref so re-created callbacks do not re-bind the listeners.
  const handlersRef = useRef(handlers)
  handlersRef.current = handlers

  useEffect(() => {
    const unsubscribers = [
      onDesktopMenu('menu:new-invoice', () => navigate('/invoices/new')),
      onDesktopMenu('menu:new-receipt', () => navigate('/receipts/new')),
      onDesktopMenu('menu:import-scan', () => navigate('/expenses?import=1')),
      onDesktopMenu('menu:palette', () => handlersRef.current.openPalette()),
      onDesktopMenu('menu:shortcuts', () => handlersRef.current.openShortcuts()),
      onDesktopMenu('menu:backup', () => navigate('/settings?backup=1')),
      onDesktopMenu('menu:print', () => window.print()),
    ]
    return () => unsubscribers.forEach((off) => off())
  }, [navigate])
}

/**
 * The editor renders at several routes, and React would otherwise reuse the
 * same component instance across them — leaving the previous draft in place
 * when you go from "New invoice" straight to "New receipt".
 *
 * The key includes `location.key`, which React Router changes on every
 * navigation, so navigating to the route you are already on also starts fresh.
 * Keying on the path alone left a half-filled form in place when you pressed
 * "New invoice" from inside a new invoice.
 */
function KeyedDocumentEdit({ kind }: { kind?: DocumentKind }) {
  const location = useLocation()
  return (
    <DocumentEdit
      key={`${location.pathname}${location.search}#${location.key}`}
      kind={kind}
    />
  )
}

export function App() {
  const ready = useApp((s) => s.ready)
  const init = useApp((s) => s.init)
  const companies = useCompanies()
  const navigate = useNavigate()

  const [paletteOpen, setPaletteOpen] = useState(false)
  const [shortcutsOpen, setShortcutsOpen] = useState(false)

  useBrandTheme()
  useDesktopMenu({
    openPalette: () => setPaletteOpen(true),
    openShortcuts: () => setShortcutsOpen(true),
  })

  // A stable array, so the listener is bound once rather than every render.
  const shortcuts = useMemo<Shortcut[]>(() => {
    // A shortcut that navigates must not silently bin an unsaved document.
    const go = (to: string) => async () => {
      if (await confirmNavigation()) navigate(to)
    }
    return [
      { key: 'k', mod: true, run: () => setPaletteOpen((v) => !v) },
      { key: 'n', mod: true, run: go('/invoices/new') },
      { key: 'n', mod: true, shift: true, run: go('/receipts/new') },
      { key: 'i', mod: true, run: go('/expenses?import=1') },
      { key: '?', run: () => setShortcutsOpen(true) },
    ]
  }, [navigate])
  useShortcuts(shortcuts, ready)

  useEffect(() => {
    void init()
  }, [init])

  // Any recurring invoice whose date has passed becomes a draft. This runs once
  // per app start rather than on a timer: there is no server, so "when the app
  // is open" is the only moment anything can happen. `catchUpRecurring` shares
  // one in-flight promise, so StrictMode's double effect cannot double-generate.
  const toast = useApp((s) => s.toast)
  useEffect(() => {
    if (!ready) return
    void catchUpRecurring().then((created) => {
      if (created.length === 0) return
      toast(
        created.length === 1
          ? `${created[0]!.number} was due today — created as a draft`
          : `${created.length} recurring invoices were due — created as drafts`,
        'info',
      )
    })
  }, [ready, toast])

  if (!ready || companies === undefined) {
    return (
      <div className="flex h-full items-center justify-center" role="status" aria-busy="true">
        <div className="flex flex-col items-center gap-3">
          <div
            className="h-9 w-9 animate-spin rounded-full border-[3px] border-[color:var(--border)]"
            style={{ borderTopColor: 'var(--brand)' }}
            aria-hidden
          />
          <p className="text-[14px] text-[color:var(--text-muted)]">Opening your books…</p>
        </div>
      </div>
    )
  }

  // No companies at all — nothing else in the app would make sense yet.
  if (companies.length === 0) {
    return (
      <>
        <Welcome />
        <Toaster />
      </>
    )
  }

  return (
    <div className="flex min-h-full flex-col">
      {/* A 3px strip in the active company's colour: on a phone, where the
          switcher is compressed, this is the clearest "which books am I in". */}
      <div
        className="no-print h-[3px] w-full shrink-0"
        style={{ background: 'var(--brand)' }}
        aria-hidden
      />
      <a
        href="#main"
        className="no-print sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded-lg focus:bg-[color:var(--surface)] focus:px-4 focus:py-2 focus:shadow-pop"
      >
        Skip to content
      </a>
      <TopBar onOpenPalette={() => setPaletteOpen(true)} />
      <main id="main" className="mx-auto w-full max-w-[1400px] flex-1 px-4 py-7 sm:px-6">
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/invoices" element={<Documents kind="invoice" />} />
          <Route path="/receipts" element={<Documents kind="receipt" />} />
          <Route path="/invoices/new" element={<KeyedDocumentEdit kind="invoice" />} />
          <Route path="/receipts/new" element={<KeyedDocumentEdit kind="receipt" />} />
          <Route path="/documents/:id" element={<DocumentView />} />
          <Route path="/documents/:id/edit" element={<KeyedDocumentEdit />} />
          <Route path="/expenses" element={<Expenses />} />
          <Route path="/reports" element={<Reports />} />
          <Route path="/clients" element={<Clients />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} />
      <ShortcutsDialog open={shortcutsOpen} onClose={() => setShortcutsOpen(false)} />
      <Toaster />
    </div>
  )
}
