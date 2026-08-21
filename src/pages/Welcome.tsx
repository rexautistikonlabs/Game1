import { useState } from 'react'
import { Sparkles, Upload } from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card } from '../components/ui/Card'
import { CompanyForm } from '../components/CompanyForm'
import { CompanyIllustration } from '../components/ui/Illustrations'
import { blankCompany, resetToSampleData } from '../db/seed'
import { restoreBackup } from '../lib/backup'
import { readFileAsText } from '../lib/download'
import { db, seedCategories } from '../db/db'
import { useApp } from '../store/useApp'
import type { Company } from '../types'

/**
 * Shown only when there are no companies at all — after a wipe, or on a
 * genuinely fresh install where seeding was skipped. Three ways forward, all
 * one click away.
 */
export function Welcome() {
  const [mode, setMode] = useState<'choose' | 'create'>('choose')
  const [busy, setBusy] = useState(false)
  const toast = useApp((s) => s.toast)
  const refresh = useApp((s) => s.refresh)

  const createCompany = async (company: Company) => {
    await db.companies.add(company)
    await seedCategories(company.id)
    await useApp.getState().setActiveCompany(company.id)
    toast(`${company.name} is ready to go`)
  }

  const loadSample = async () => {
    setBusy(true)
    try {
      await resetToSampleData()
      await refresh()
      toast('Sample companies loaded')
    } finally {
      setBusy(false)
    }
  }

  const restore = async (file?: File) => {
    if (!file) return
    setBusy(true)
    try {
      const result = await restoreBackup(await readFileAsText(file), 'replace')
      await refresh()
      toast(`Restored ${result.companies} companies and ${result.documents} documents`)
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not read that backup.', 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto flex min-h-full w-full max-w-3xl flex-col justify-center px-5 py-12">
      {mode === 'choose' ? (
        <div className="text-center">
          <div className="mb-6 flex justify-center">
            <CompanyIllustration />
          </div>
          <h1 className="text-[34px] font-semibold leading-tight tracking-[-0.03em]">
            Welcome to SimpleBooks
          </h1>
          <p className="mx-auto mt-3 max-w-lg text-[16px] leading-relaxed text-[color:var(--text-muted)]">
            Invoices, receipts and expenses for as many companies as you like. Everything
            stays on this computer — no account, no cloud, no subscription.
          </p>

          <div className="mt-9 flex flex-col items-center gap-3">
            <Button variant="brand" size="lg" onClick={() => setMode('create')} className="w-full sm:w-80">
              Add your first company
            </Button>
            <Button variant="secondary" size="lg" onClick={loadSample} loading={busy} className="w-full sm:w-80">
              <Sparkles className="h-4 w-4" aria-hidden />
              Explore with sample data
            </Button>
            <label className="w-full sm:w-80">
              <input
                type="file"
                accept="application/json,.json"
                className="hidden"
                onChange={(event) => void restore(event.target.files?.[0])}
              />
              <span className="flex h-12 w-full cursor-pointer items-center justify-center gap-2.5 rounded-xl px-6 text-[15px] font-medium text-[color:var(--text-muted)] transition hover:bg-black/5 dark:hover:bg-white/10">
                <Upload className="h-4 w-4" aria-hidden />
                Restore a backup
              </span>
            </label>
          </div>
        </div>
      ) : (
        <Card className="animate-slide-up sm:p-7">
          <h1 className="text-[24px] font-semibold tracking-[-0.02em]">Add your company</h1>
          <p className="mt-1.5 text-[14.5px] text-[color:var(--text-muted)]">
            Only the name is required — you can fill in the rest whenever you like.
          </p>
          <div className="mt-7">
            <CompanyForm
              company={blankCompany()}
              onSubmit={createCompany}
              onCancel={() => setMode('choose')}
              submitLabel="Create company"
              compact
            />
          </div>
        </Card>
      )}
    </div>
  )
}
