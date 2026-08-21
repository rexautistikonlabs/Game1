import { NavLink, useNavigate } from 'react-router-dom'
import {
  FileText,
  LayoutDashboard,
  Moon,
  Plus,
  Receipt,
  ScanLine,
  Settings as SettingsIcon,
  Sun,
  Users,
  Wallet,
} from 'lucide-react'
import { CompanySwitcher } from './CompanySwitcher'
import { Button } from './ui/Button'
import { useApp } from '../store/useApp'
import { cn } from '../lib/cn'

const NAV_ITEMS = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/invoices', label: 'Invoices', icon: FileText },
  { to: '/receipts', label: 'Receipts', icon: Receipt },
  { to: '/expenses', label: 'Expenses', icon: Wallet },
  { to: '/clients', label: 'Clients', icon: Users },
  { to: '/settings', label: 'Settings', icon: SettingsIcon },
]

export function TopBar() {
  const navigate = useNavigate()
  const theme = useApp((s) => s.theme)
  const setTheme = useApp((s) => s.setTheme)

  return (
    <header
      className="no-print sticky top-0 z-30 border-b backdrop-blur-xl"
      style={{ background: 'color-mix(in srgb, var(--surface) 88%, transparent)' }}
    >
      <div className="mx-auto flex max-w-[1400px] items-center gap-3 px-4 py-2.5 sm:px-6">
        <div className="flex shrink-0 items-center gap-3">
          <span
            className="flex h-8 w-8 items-center justify-center rounded-lg text-[15px] font-bold text-white"
            style={{ background: 'var(--brand)' }}
            aria-hidden
          >
            S
          </span>
          <span className="hidden text-[15px] font-semibold tracking-[-0.02em] lg:block">
            SimpleBooks
          </span>
          <span className="mx-1 hidden h-6 w-px bg-[color:var(--border)] lg:block" />
        </div>

        <CompanySwitcher />

        <div className="ml-auto flex shrink-0 items-center gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => navigate('/expenses?import=1')}
            className="hidden sm:inline-flex"
          >
            <ScanLine className="h-4 w-4" aria-hidden />
            Import scan
          </Button>
          <Button variant="brand" size="sm" onClick={() => navigate('/invoices/new')}>
            <Plus className="h-4 w-4" aria-hidden />
            <span className="hidden sm:inline">New invoice</span>
            <span className="sm:hidden">New</span>
          </Button>
          <button
            onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')}
            className="flex h-8 w-8 items-center justify-center rounded-lg text-[color:var(--text-muted)] transition hover:bg-black/5 hover:text-[color:var(--text)] dark:hover:bg-white/10"
            aria-label={theme === 'light' ? 'Switch to dark theme' : 'Switch to light theme'}
            title={theme === 'light' ? 'Dark theme' : 'Light theme'}
          >
            {theme === 'light' ? <Moon className="h-4 w-4" /> : <Sun className="h-4 w-4" />}
          </button>
        </div>
      </div>

      <nav className="mx-auto max-w-[1400px] px-2 sm:px-4">
        <ul className="flex items-center gap-0.5 overflow-x-auto">
          {NAV_ITEMS.map(({ to, label, icon: Icon, end }) => (
            <li key={to}>
              <NavLink
                to={to}
                end={end}
                className={({ isActive }) =>
                  cn(
                    'relative flex items-center gap-2 whitespace-nowrap px-3 py-2.5 text-[14px] font-medium transition',
                    isActive
                      ? 'text-[color:var(--text)]'
                      : 'text-[color:var(--text-muted)] hover:text-[color:var(--text)]',
                  )
                }
              >
                {({ isActive }) => (
                  <>
                    <Icon className="h-4 w-4" aria-hidden />
                    {label}
                    {isActive ? (
                      <span
                        className="absolute inset-x-2 -bottom-px h-[2.5px] rounded-full"
                        style={{ background: 'var(--brand)' }}
                        aria-hidden
                      />
                    ) : null}
                  </>
                )}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
    </header>
  )
}
