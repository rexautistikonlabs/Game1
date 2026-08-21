import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import {
  Building2,
  Check,
  HardDriveDownload,
  Info,
  Monitor,
  Moon,
  Pencil,
  Plus,
  RefreshCw,
  Sun,
  Trash2,
  Upload,
} from 'lucide-react'
import { Button, IconButton } from '../components/ui/Button'
import { Card, SectionTitle } from '../components/ui/Card'
import { Chip } from '../components/ui/Badge'
import { CompanyAvatar } from '../components/CompanySwitcher'
import { CompanyForm } from '../components/CompanyForm'
import { Modal } from '../components/ui/Modal'
import { PageHeader } from '../components/PageHeader'
import { Segmented } from '../components/ui/SearchInput'
import { CardsSkeleton } from '../components/ui/Skeleton'
import { useConfirm } from '../components/ui/Confirm'
import { db, deleteCompanyCascade } from '../db/db'
import { backupFilename, createBackup, restoreBackup } from '../lib/backup'
import { blankCompany, resetToSampleData } from '../db/seed'
import { isDesktop, readFileAsText, saveFile } from '../lib/download'
import { useApp } from '../store/useApp'
import { useActiveCompany, useCompanies } from '../store/useCompanyData'
import type { Company } from '../types'

/** Everything configurable lives on this one page — nothing is buried. */
export function Settings() {
  const companies = useCompanies()
  const active = useActiveCompany()
  const [searchParams, setSearchParams] = useSearchParams()
  const toast = useApp((s) => s.toast)
  const refresh = useApp((s) => s.refresh)
  const setActiveCompany = useApp((s) => s.setActiveCompany)
  const theme = useApp((s) => s.theme)
  const setTheme = useApp((s) => s.setTheme)
  const { confirm, dialog } = useConfirm()

  const [editing, setEditing] = useState<Company | null>(null)
  const [creating, setCreating] = useState(false)
  const [busy, setBusy] = useState(false)
  const restoreInputRef = useRef<HTMLInputElement>(null)

  // Deep links: ?new=company from the switcher, ?backup=1 from the desktop menu.
  useEffect(() => {
    if (searchParams.get('new') === 'company') setCreating(true)
    if (searchParams.get('backup')) void backup()
    if (searchParams.get('new') || searchParams.get('backup')) {
      const next = new URLSearchParams(searchParams)
      next.delete('new')
      next.delete('backup')
      setSearchParams(next, { replace: true })
    }
    // Deliberately keyed on the query string alone: this should fire when a
    // deep link arrives, not when the handlers below are re-created.
  }, [searchParams])

  if (!companies || !active) return <CardsSkeleton cards={2} label="Loading settings" />

  const saveCompany = async (company: Company) => {
    const isNew = !companies.some((c) => c.id === company.id)
    await db.companies.put(company)
    if (isNew) await setActiveCompany(company.id)
    toast(isNew ? `${company.name} added` : `${company.name} saved`)
    setEditing(null)
    setCreating(false)
  }

  const removeCompany = async (company: Company) => {
    if (companies.length === 1) {
      toast('Keep at least one company — SimpleBooks needs somewhere to put things.', 'error')
      return
    }
    const [documents, expenses, clients] = await Promise.all([
      db.documents.where('companyId').equals(company.id).count(),
      db.expenses.where('companyId').equals(company.id).count(),
      db.clients.where('companyId').equals(company.id).count(),
    ])

    const ok = await confirm({
      title: `Delete ${company.name}?`,
      message: (
        <>
          This permanently deletes{' '}
          <strong>
            {documents} {documents === 1 ? 'document' : 'documents'}, {expenses}{' '}
            {expenses === 1 ? 'expense' : 'expenses'} and {clients}{' '}
            {clients === 1 ? 'client' : 'clients'}
          </strong>{' '}
          along with the company itself. Export a backup first if you might want any of it back.
        </>
      ),
      confirmLabel: 'Delete everything',
      destructive: true,
    })
    if (!ok) return

    await deleteCompanyCascade(company.id)
    await refresh()
    toast(`${company.name} deleted`, 'info')
  }

  const backup = async () => {
    setBusy(true)
    try {
      const data = await createBackup()
      const saved = await saveFile(
        backupFilename(),
        JSON.stringify(data, null, 2),
        'application/json',
      )
      if (saved) toast('Backup saved')
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Backup failed.', 'error')
    } finally {
      setBusy(false)
    }
  }

  const restore = async (file?: File) => {
    if (!file) return
    const ok = await confirm({
      title: 'Restore this backup?',
      message:
        'Everything currently in SimpleBooks is replaced by the contents of the backup file. This cannot be undone.',
      confirmLabel: 'Replace everything',
      destructive: true,
    })
    if (!ok) return

    setBusy(true)
    try {
      const result = await restoreBackup(await readFileAsText(file), 'replace')
      await refresh()
      toast(
        `Restored ${result.companies} companies, ${result.documents} documents and ${result.expenses} expenses`,
      )
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not read that backup.', 'error')
    } finally {
      setBusy(false)
      if (restoreInputRef.current) restoreInputRef.current.value = ''
    }
  }

  const resetDemo = async () => {
    const ok = await confirm({
      title: 'Reset to sample data?',
      message:
        'This deletes everything and puts the two example companies back. Useful for a demo, ruinous for real books.',
      confirmLabel: 'Delete everything and reset',
      destructive: true,
    })
    if (!ok) return
    setBusy(true)
    try {
      await resetToSampleData()
      await refresh()
      toast('Sample data restored')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title="Settings"
        subtitle="Companies, appearance and your data. That is the whole of it."
      />

      <div className="space-y-5">
        {/* ---- Companies ---- */}
        <Card className="space-y-5">
          <SectionTitle
            title="Companies"
            subtitle="Each one keeps its own clients, documents, numbering and branding."
            action={
              <Button variant="brand" onClick={() => setCreating(true)}>
                <Plus className="h-4 w-4" aria-hidden />
                Add company
              </Button>
            }
          />

          <div className="divide-y">
            {companies.map((company) => (
              <div key={company.id} className="flex items-center gap-4 py-3.5 first:pt-0">
                <CompanyAvatar company={company} size={40} />
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="truncate text-[15px] font-semibold">{company.name}</span>
                    {company.id === active.id ? (
                      <Chip tone="brand">
                        <Check className="h-3 w-3" aria-hidden />
                        Active
                      </Chip>
                    ) : null}
                    <Chip>{company.type === 'nonprofit' ? 'Nonprofit' : 'For-profit'}</Chip>
                  </div>
                  <p className="mt-0.5 truncate text-[13px] text-[color:var(--text-muted)]">
                    {[company.currency, company.taxId, company.email].filter(Boolean).join(' · ') ||
                      'No details yet'}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  {company.id !== active.id ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => void setActiveCompany(company.id)}
                    >
                      Switch to
                    </Button>
                  ) : null}
                  <IconButton
                    variant="ghost"
                    size="sm"
                    onClick={() => setEditing(company)}
                    aria-label={`Edit ${company.name}`}
                  >
                    <Pencil className="h-4 w-4" aria-hidden />
                  </IconButton>
                  <IconButton
                    variant="ghost"
                    size="sm"
                    onClick={() => void removeCompany(company)}
                    aria-label={`Delete ${company.name}`}
                    className="hover:text-red-600"
                  >
                    <Trash2 className="h-4 w-4" aria-hidden />
                  </IconButton>
                </div>
              </div>
            ))}
          </div>
        </Card>

        {/* ---- Appearance ---- */}
        <Card className="space-y-4">
          <SectionTitle
            title="Appearance"
            subtitle="Documents always print on white paper, whichever theme you use."
          />
          <Segmented
            value={theme}
            onChange={(next) => void setTheme(next)}
            options={[
              { value: 'light', label: 'Light' },
              { value: 'dark', label: 'Dark' },
            ]}
          />
          <p className="flex items-center gap-2 text-[13px] text-[color:var(--text-muted)]">
            {theme === 'light' ? (
              <Sun className="h-3.5 w-3.5" aria-hidden />
            ) : (
              <Moon className="h-3.5 w-3.5" aria-hidden />
            )}
            The app takes its accent colour from whichever company you are working in.
          </p>
        </Card>

        {/* ---- Data ---- */}
        <Card className="space-y-5">
          <SectionTitle
            title="Your data"
            subtitle="Stored on this computer only. A backup is the one thing worth doing regularly."
          />

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Button variant="secondary" size="lg" onClick={backup} loading={busy} block>
              <HardDriveDownload className="h-4 w-4" aria-hidden />
              Export backup (JSON)
            </Button>
            <input
              ref={restoreInputRef}
              type="file"
              accept="application/json,.json"
              className="hidden"
              onChange={(event) => void restore(event.target.files?.[0])}
            />
            <Button
              variant="secondary"
              size="lg"
              onClick={() => restoreInputRef.current?.click()}
              block
            >
              <Upload className="h-4 w-4" aria-hidden />
              Restore from backup
            </Button>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border px-4 py-3.5">
            <div>
              <p className="text-[14px] font-medium">Sample data</p>
              <p className="mt-0.5 text-[13px] text-[color:var(--text-muted)]">
                Replace everything with the two example companies.
              </p>
            </div>
            <Button variant="ghost" onClick={resetDemo} loading={busy}>
              <RefreshCw className="h-4 w-4" aria-hidden />
              Reset demo data
            </Button>
          </div>

          <div
            className="flex items-start gap-3 rounded-xl px-4 py-3.5 text-[13px] leading-relaxed"
            style={{ background: 'var(--brand-soft)' }}
          >
            <Info className="mt-0.5 h-4 w-4 shrink-0 text-[color:var(--brand)]" aria-hidden />
            <p>
              Nothing in SimpleBooks ever leaves this computer — no account, no server, no
              telemetry. Your books live in this{' '}
              {isDesktop() ? "app's local database" : "browser's local database"}, which is exactly
              why the backup button matters.
            </p>
          </div>
        </Card>

        {/* ---- About ---- */}
        <Card className="space-y-2">
          <SectionTitle title="About SimpleBooks" />
          <p className="text-[13.5px] leading-relaxed text-[color:var(--text-muted)]">
            Version 1.0.0 · Offline-first invoices, receipts and expenses for as many companies as
            you like.
          </p>
          <p className="flex items-center gap-2 text-[13px] text-[color:var(--text-subtle)]">
            {isDesktop() ? (
              <>
                <Monitor className="h-3.5 w-3.5" aria-hidden />
                Running as a desktop app
              </>
            ) : (
              <>
                <Building2 className="h-3.5 w-3.5" aria-hidden />
                Running in a browser — everything still works offline
              </>
            )}
          </p>
        </Card>
      </div>

      {/* ---- Company editor ---- */}
      <Modal
        open={creating || editing !== null}
        onClose={() => {
          setCreating(false)
          setEditing(null)
        }}
        title={editing ? `Edit ${editing.name}` : 'Add a company'}
        description={
          editing
            ? 'Changes apply to new documents. Documents you have already saved keep the details they were issued with.'
            : 'Only the name is required — everything else has a sensible default.'
        }
        size="lg"
      >
        <CompanyForm
          key={editing?.id ?? 'new'}
          company={editing ?? blankCompany()}
          onSubmit={saveCompany}
          onCancel={() => {
            setCreating(false)
            setEditing(null)
          }}
          submitLabel={editing ? 'Save changes' : 'Add company'}
        />
      </Modal>

      {dialog}
    </div>
  )
}
