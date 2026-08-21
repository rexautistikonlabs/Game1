import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import {
  ArrowLeft,
  CalendarPlus,
  CheckCircle2,
  Copy,
  Download,
  Mail,
  Pencil,
  Printer,
  Repeat,
  Send,
  Trash2,
} from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card } from '../components/ui/Card'
import { Chip } from '../components/ui/Badge'
import { DocumentSheet } from '../components/DocumentSheet'
import { EmailDialog } from '../components/EmailDialog'
import { SheetPreview } from '../components/SheetPreview'

import { StatusBadge } from '../components/ui/Badge'
import { useConfirm } from '../components/ui/Confirm'
import { db } from '../db/db'
import { saveFile } from '../lib/download'
import {
  computeTotals,
  daysOverdue,
  displayStatus,
  formatDate,
  formatMoney,
  today,
} from '../lib/format'
import { generatePdfBlob, pdfFilename, printDocument } from '../lib/pdf'
import { generateNext, isDue, seriesMembers } from '../lib/recurrence'
import { useApp } from '../store/useApp'
import { useActiveCompany, useDocument } from '../store/useCompanyData'
import { RECURRENCE_LABELS, type Document, type DocumentStatus } from '../types'

/**
 * The finished document, exactly as it will print, with every action it
 * supports in one column beside it.
 */
export function DocumentView() {
  const { id } = useParams()
  const navigate = useNavigate()
  const doc = useDocument(id)
  const company = useActiveCompany()
  const toast = useApp((s) => s.toast)
  const { confirm, dialog } = useConfirm()

  const sheetRef = useRef<HTMLDivElement>(null)
  const [emailOpen, setEmailOpen] = useState(false)
  const [pdfBusy, setPdfBusy] = useState(false)
  const [generating, setGenerating] = useState(false)
  const [series, setSeries] = useState<Document[]>([])

  // Ctrl+P should print the document sheet alone, not the surrounding app.
  useEffect(() => {
    document.body.classList.add('printing-document')
    return () => document.body.classList.remove('printing-document')
  }, [])

  // Sibling invoices, so a member of a series can see the whole series.
  useEffect(() => {
    if (!doc || (!doc.recurrence && !doc.seriesId)) {
      setSeries([])
      return
    }
    let cancelled = false
    void seriesMembers(doc).then((members) => {
      if (!cancelled) setSeries(members)
    })
    return () => {
      cancelled = true
    }
  }, [doc])

  if (doc === undefined || !company) return null

  if (doc === null) {
    return (
      <Card className="mx-auto max-w-md text-center">
        <p className="text-[15px]">That document no longer exists.</p>
        <Button variant="secondary" className="mt-4" onClick={() => navigate('/invoices')}>
          Back to invoices
        </Button>
      </Card>
    )
  }

  const totals = computeTotals(doc)
  const status = displayStatus(doc)
  const isInvoice = doc.kind === 'invoice'
  const overdueBy = daysOverdue(doc)

  const setStatus = async (next: DocumentStatus) => {
    await db.documents.update(doc.id, {
      status: next,
      paidDate: next === 'paid' ? (doc.paidDate ?? today()) : undefined,
      updatedAt: new Date().toISOString(),
    })
    toast(
      next === 'paid'
        ? `${doc.number} marked as paid`
        : next === 'sent'
          ? `${doc.number} marked as sent`
          : `${doc.number} moved back to draft`,
    )
  }

  const downloadPdf = async () => {
    if (!sheetRef.current) return
    setPdfBusy(true)
    try {
      const blob = await generatePdfBlob(sheetRef.current)
      const saved = await saveFile(pdfFilename(doc), blob, 'application/pdf')
      if (saved) toast('PDF saved')
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not create the PDF.', 'error')
    } finally {
      setPdfBusy(false)
    }
  }

  const remove = async () => {
    const ok = await confirm({
      title: `Delete ${doc.number}?`,
      message: `This permanently removes the ${doc.kind} for ${doc.client.name}. Number ${doc.number} will not be reused.`,
      confirmLabel: 'Delete',
      destructive: true,
    })
    if (!ok) return
    await db.documents.delete(doc.id)
    toast(`${doc.number} deleted`, 'info')
    navigate(isInvoice ? '/invoices' : '/receipts', { replace: true })
  }

  const duplicate = () => navigate(`/${doc.kind}s/new?duplicate=${doc.id}`)

  const generate = async () => {
    setGenerating(true)
    try {
      const created = await generateNext(doc.id)
      if (!created) {
        toast('Nothing is due yet in this series.', 'info')
        return
      }
      toast(`${created.number} created as a draft`)
      navigate(`/documents/${created.id}`)
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not create the next invoice.', 'error')
    } finally {
      setGenerating(false)
    }
  }

  return (
    <div>
      {/* ---- Header ---- */}
      <div className="no-print mb-6 flex flex-wrap items-center gap-3">
        <Button variant="ghost" size="sm" onClick={() => navigate(isInvoice ? '/invoices' : '/receipts')}>
          <ArrowLeft className="h-4 w-4" aria-hidden />
          {isInvoice ? 'Invoices' : 'Receipts'}
        </Button>
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2.5">
            <h1 className="tabular text-[22px] font-semibold leading-tight tracking-[-0.02em]">
              {doc.number}
            </h1>
            <StatusBadge status={status} />
            {doc.recurrence ? (
              <Chip tone="brand">
                <Repeat className="h-3 w-3" aria-hidden />
                {RECURRENCE_LABELS[doc.recurrence]}
              </Chip>
            ) : doc.seriesId ? (
              <Chip>
                <Repeat className="h-3 w-3" aria-hidden />
                Part of a series
              </Chip>
            ) : null}
          </div>
          <p className="mt-0.5 text-[13px] text-[color:var(--text-muted)]">
            {doc.client.name} · {formatDate(doc.issueDate)} ·{' '}
            {formatMoney(totals.total, doc.currency)}
            {overdueBy > 0 ? (
              <span className="ml-1 font-medium text-red-600 dark:text-red-400">
                · {overdueBy} {overdueBy === 1 ? 'day' : 'days'} overdue
              </span>
            ) : null}
          </p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2.5">
          <Button variant="secondary" onClick={() => navigate(`/documents/${doc.id}/edit`)}>
            <Pencil className="h-4 w-4" aria-hidden />
            Edit
          </Button>
          <Button variant="brand" onClick={printDocument}>
            <Printer className="h-4 w-4" aria-hidden />
            Print
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1fr)_17rem]">
        {/* ---- The document ---- */}
        <SheetPreview className="rounded-lg">
          <DocumentSheet ref={sheetRef} doc={doc} company={company} />
        </SheetPreview>

        {/* ---- Actions ---- */}
        <div className="no-print space-y-4 lg:sticky lg:top-32 lg:self-start">
          <Card className="space-y-2.5">
            <p className="text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              Share
            </p>
            <Button block variant="secondary" onClick={printDocument}>
              <Printer className="h-4 w-4" aria-hidden />
              Print
            </Button>
            <Button block variant="secondary" onClick={downloadPdf} loading={pdfBusy}>
              <Download className="h-4 w-4" aria-hidden />
              Save as PDF
            </Button>
            <Button block variant="secondary" onClick={() => setEmailOpen(true)}>
              <Mail className="h-4 w-4" aria-hidden />
              Email
            </Button>
          </Card>

          <Card className="space-y-2.5">
            <p className="text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              Status
            </p>
            {doc.status !== 'paid' ? (
              <Button block variant="brand" onClick={() => setStatus('paid')}>
                <CheckCircle2 className="h-4 w-4" aria-hidden />
                Mark as paid
              </Button>
            ) : (
              <Button block variant="secondary" onClick={() => setStatus('sent')}>
                Reopen as unpaid
              </Button>
            )}
            {doc.status === 'draft' ? (
              <Button block variant="secondary" onClick={() => setStatus('sent')}>
                <Send className="h-4 w-4" aria-hidden />
                Mark as sent
              </Button>
            ) : null}
          </Card>

          {doc.recurrence || series.length > 1 ? (
            <Card className="space-y-3">
              <p className="text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
                Recurring series
              </p>

              {doc.recurrence && doc.nextIssueDate ? (
                <>
                  <p className="text-[13.5px] leading-relaxed text-[color:var(--text-muted)]">
                    Repeats {RECURRENCE_LABELS[doc.recurrence].toLowerCase()}. Next copy dated{' '}
                    <span className="font-medium text-[color:var(--text)]">
                      {formatDate(doc.nextIssueDate)}
                    </span>
                    {doc.recurrenceEndDate
                      ? `, ending ${formatDate(doc.recurrenceEndDate)}`
                      : ''}
                    .
                  </p>
                  <Button
                    block
                    variant={isDue(doc) ? 'brand' : 'secondary'}
                    onClick={generate}
                    loading={generating}
                    disabled={!isDue(doc)}
                    title={
                      isDue(doc)
                        ? 'Create the next invoice now'
                        : `Available on ${formatDate(doc.nextIssueDate)}`
                    }
                  >
                    <CalendarPlus className="h-4 w-4" aria-hidden />
                    {isDue(doc) ? 'Generate next now' : 'Not due yet'}
                  </Button>
                </>
              ) : null}

              {series.length > 1 ? (
                <div className="space-y-1 border-t pt-3">
                  <p className="mb-1.5 text-[12.5px] text-[color:var(--text-muted)]">
                    {series.length} invoices in this series
                  </p>
                  {series.map((member) => (
                    <button
                      key={member.id}
                      onClick={() => navigate(`/documents/${member.id}`)}
                      disabled={member.id === doc.id}
                      className="flex w-full items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-left text-[13px] transition enabled:hover:bg-black/5 disabled:font-semibold dark:enabled:hover:bg-white/10"
                    >
                      <span className="tabular truncate">{member.number}</span>
                      <span className="shrink-0 text-[color:var(--text-subtle)]">
                        {formatDate(member.issueDate)}
                      </span>
                    </button>
                  ))}
                </div>
              ) : null}
            </Card>
          ) : null}

          <Card className="space-y-2.5">
            <p className="text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              Manage
            </p>
            <Button block variant="secondary" onClick={duplicate}>
              <Copy className="h-4 w-4" aria-hidden />
              Duplicate
            </Button>
            <Button
              block
              variant="ghost"
              onClick={remove}
              className="text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-500/10"
            >
              <Trash2 className="h-4 w-4" aria-hidden />
              Delete
            </Button>
          </Card>
        </div>
      </div>

      <EmailDialog
        open={emailOpen}
        onClose={() => setEmailOpen(false)}
        doc={doc}
        company={company}
        sheetRef={sheetRef}
        onSent={() => {
          // Emailing an invoice is the moment it stops being a draft.
          if (doc.status === 'draft') void setStatus('sent')
        }}
      />
      {dialog}
    </div>
  )
}
