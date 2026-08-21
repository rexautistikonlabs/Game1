import { useState } from 'react'
import { Mail, Paperclip } from 'lucide-react'
import { Button } from './ui/Button'
import { Field, Input, Textarea } from './ui/Input'
import { Modal } from './ui/Modal'
import { buildMailto, generatePdfBlob, openMailClient, pdfFilename } from '../lib/pdf'
import { saveFile } from '../lib/download'
import { computeTotals, formatDateLong, formatMoney } from '../lib/format'
import { useApp } from '../store/useApp'
import type { Company, Document } from '../types'

/**
 * No email client on any platform lets a `mailto:` link carry an attachment.
 * Rather than pretend otherwise, SimpleBooks saves the PDF for you and opens a
 * ready-written email — so the only thing left to do is drag the file in.
 */
export function EmailDialog({
  open,
  onClose,
  doc,
  company,
  sheetRef,
  onSent,
}: {
  open: boolean
  onClose: () => void
  doc: Document
  company: Company
  sheetRef: React.RefObject<HTMLDivElement>
  onSent?: () => void
}) {
  const toast = useApp((s) => s.toast)
  const totals = computeTotals(doc)
  const isInvoice = doc.kind === 'invoice'

  const [to, setTo] = useState(doc.client.email ?? '')
  const [subject, setSubject] = useState(
    isInvoice
      ? `Invoice ${doc.number} from ${company.name}`
      : `Receipt ${doc.number} from ${company.name}`,
  )
  const [body, setBody] = useState(
    isInvoice
      ? `Hi ${doc.client.name.split(' ')[0] || 'there'},\n\n` +
          `Please find invoice ${doc.number} for ${formatMoney(totals.total, doc.currency)} attached.\n` +
          (doc.dueDate ? `It is due on ${formatDateLong(doc.dueDate)}.\n` : '') +
          (company.paymentDetails ? `\nHow to pay:\n${company.paymentDetails}\n` : '') +
          `\nThank you,\n${company.name}`
      : `Hi ${doc.client.name.split(' ')[0] || 'there'},\n\n` +
          `Thank you — here is receipt ${doc.number} confirming ${formatMoney(
            totals.total,
            doc.currency,
          )} received on ${formatDateLong(doc.issueDate)}.\n\n` +
          `Best regards,\n${company.name}`,
  )
  const [attachPdf, setAttachPdf] = useState(true)
  const [busy, setBusy] = useState(false)

  const send = async () => {
    setBusy(true)
    try {
      if (attachPdf) {
        const element = sheetRef.current
        if (!element) throw new Error('The document is not ready yet — try again in a moment.')
        const blob = await generatePdfBlob(element)
        const saved = await saveFile(pdfFilename(doc), blob, 'application/pdf')
        if (!saved) {
          setBusy(false)
          return
        }
        toast(`PDF saved as ${pdfFilename(doc)} — attach it to the email that just opened.`, 'info')
      }

      openMailClient(buildMailto({ to, subject, body }))
      onSent?.()
      onClose()
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not prepare the email.', 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Email ${doc.kind} ${doc.number}`}
      description="SimpleBooks saves the PDF and opens your email app with the message written."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="brand" onClick={send} loading={busy}>
            <Mail className="h-4 w-4" aria-hidden />
            {attachPdf ? 'Save PDF & open email' : 'Open email'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="To">
          <Input
            type="email"
            value={to}
            onChange={(event) => setTo(event.target.value)}
            placeholder="client@example.com"
          />
        </Field>
        <Field label="Subject">
          <Input value={subject} onChange={(event) => setSubject(event.target.value)} />
        </Field>
        <Field label="Message">
          <Textarea rows={9} value={body} onChange={(event) => setBody(event.target.value)} />
        </Field>

        <label className="flex cursor-pointer items-start gap-2.5 rounded-xl border px-3.5 py-3 transition hover:bg-black/[0.02] dark:hover:bg-white/[0.04]">
          <input
            type="checkbox"
            checked={attachPdf}
            onChange={(event) => setAttachPdf(event.target.checked)}
            className="mt-0.5 h-4 w-4 accent-[color:var(--brand)]"
          />
          <span>
            <span className="flex items-center gap-1.5 text-[14px] font-medium">
              <Paperclip className="h-3.5 w-3.5" aria-hidden />
              Save the PDF first
            </span>
            <span className="mt-0.5 block text-[13px] text-[color:var(--text-muted)]">
              Email apps cannot accept an attachment from a link, so we save{' '}
              <span className="font-medium">{pdfFilename(doc)}</span> and you drag it in.
            </span>
          </span>
        </label>
      </div>
    </Modal>
  )
}
