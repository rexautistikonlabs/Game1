import { useCallback, useEffect, useRef, useState } from 'react'
import { FileUp, RotateCcw, ScanLine, Sparkles } from 'lucide-react'
import { Button } from './ui/Button'
import { Field, Input, MoneyInput, Select, Textarea } from './ui/Input'
import { Modal } from './ui/Modal'
import { ScanIllustration } from './ui/Illustrations'
import { db, newId } from '../db/db'
import { currencySymbol, today } from '../lib/format'
import { scanReceipt } from '../lib/ocr'
import { useApp } from '../store/useApp'
import { cn } from '../lib/cn'
import { EXPENSE_CATEGORIES, PAYMENT_METHODS, type Company, type Expense } from '../types'

type Phase = 'drop' | 'reading' | 'review'

interface Draft {
  vendor: string
  date: string
  total: number
  taxAmount: number
  category: string
  paymentMethod: string
  notes: string
}

const ACCEPTED = 'image/png,image/jpeg,image/webp,image/gif,image/bmp,image/tiff,application/pdf'

const isSupported = (file: File) =>
  file.type.startsWith('image/') || file.type === 'application/pdf' || /\.pdf$/i.test(file.name)

/**
 * Drag in a photo or PDF of a paper receipt; Tesseract reads it locally and
 * fills in a draft expense. The extracted values are always shown for review —
 * OCR is a head start, not an authority.
 */
export function ScanImportDialog({
  open,
  onClose,
  company,
}: {
  open: boolean
  onClose: () => void
  company: Company
}) {
  const toast = useApp((s) => s.toast)
  const inputRef = useRef<HTMLInputElement>(null)

  const [phase, setPhase] = useState<Phase>('drop')
  const [dragging, setDragging] = useState(false)
  const [queue, setQueue] = useState<File[]>([])
  const [index, setIndex] = useState(0)
  const [progress, setProgress] = useState({ stage: '', percent: 0 })
  const [image, setImage] = useState<string>('')
  const [ocrText, setOcrText] = useState('')
  const [confidence, setConfidence] = useState(0)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [saving, setSaving] = useState(false)

  const reset = useCallback(() => {
    setPhase('drop')
    setQueue([])
    setIndex(0)
    setImage('')
    setOcrText('')
    setDraft(null)
    setProgress({ stage: '', percent: 0 })
  }, [])

  useEffect(() => {
    if (!open) reset()
  }, [open, reset])

  const read = useCallback(
    async (file: File) => {
      setPhase('reading')
      setProgress({ stage: 'Getting ready', percent: 0 })
      try {
        const result = await scanReceipt(file, (stage, percent) =>
          setProgress({ stage, percent }),
        )
        setImage(result.imageDataUrl)
        setOcrText(result.text)
        setConfidence(result.confidence)
        setDraft({
          vendor: result.vendor,
          date: result.date,
          total: result.total,
          taxAmount: result.taxAmount,
          category: result.category,
          paymentMethod: 'Card',
          notes: '',
        })
        setPhase('review')
      } catch (error) {
        toast(
          error instanceof Error
            ? `Could not read that receipt: ${error.message}`
            : 'Could not read that receipt.',
          'error',
        )
        setPhase('drop')
      }
    },
    [toast],
  )

  const accept = (files: FileList | File[] | null) => {
    const list = Array.from(files ?? []).filter(isSupported)
    if (!list.length) {
      toast('Drop an image (PNG, JPG…) or a PDF of a receipt.', 'error')
      return
    }
    setQueue(list)
    setIndex(0)
    void read(list[0]!)
  }

  const save = async () => {
    if (!draft) return
    if (!draft.vendor.trim()) {
      toast('Who was this paid to?', 'error')
      return
    }
    setSaving(true)
    try {
      const now = new Date().toISOString()
      let attachmentId: string | undefined

      if (image) {
        attachmentId = newId()
        await db.attachments.add({
          id: attachmentId,
          companyId: company.id,
          name: queue[index]?.name ?? 'receipt-scan',
          mimeType: 'image/png',
          data: image,
          createdAt: now,
        })
      }

      const expense: Expense = {
        id: newId(),
        companyId: company.id,
        vendor: draft.vendor.trim(),
        date: draft.date,
        total: Number(draft.total) || 0,
        taxAmount: Number(draft.taxAmount) || 0,
        category: draft.category,
        notes: draft.notes.trim() || undefined,
        currency: company.currency,
        paymentMethod: draft.paymentMethod,
        attachmentId,
        ocrText: ocrText || undefined,
        source: 'scan',
        createdAt: now,
        updatedAt: now,
      }
      await db.expenses.add(expense)
      toast(`Saved ${expense.vendor} to expenses`)

      // Straight on to the next scan if several files were dropped at once.
      const nextIndex = index + 1
      if (nextIndex < queue.length) {
        setIndex(nextIndex)
        setDraft(null)
        setImage('')
        setOcrText('')
        await read(queue[nextIndex]!)
      } else {
        onClose()
      }
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not save that expense.', 'error')
    } finally {
      setSaving(false)
    }
  }

  const patch = (changes: Partial<Draft>) => setDraft((prev) => (prev ? { ...prev, ...changes } : prev))
  const symbol = currencySymbol(company.currency)
  const queueLabel = queue.length > 1 ? ` (${index + 1} of ${queue.length})` : ''

  return (
    <Modal
      open={open}
      onClose={onClose}
      size={phase === 'review' ? 'lg' : 'md'}
      title={`Import a scanned receipt${queueLabel}`}
      description={
        phase === 'review'
          ? 'Check what we read, fix anything that is off, then save it to your expenses.'
          : 'Everything happens on this computer — the image is never uploaded anywhere.'
      }
      footer={
        phase === 'review' ? (
          <>
            <Button variant="ghost" onClick={reset}>
              <RotateCcw className="h-4 w-4" aria-hidden />
              Start over
            </Button>
            <Button variant="brand" onClick={save} loading={saving}>
              Save expense
            </Button>
          </>
        ) : undefined
      }
    >
      {phase === 'drop' ? (
        <div
          onDragOver={(event) => {
            event.preventDefault()
            setDragging(true)
          }}
          onDragLeave={() => setDragging(false)}
          onDrop={(event) => {
            event.preventDefault()
            setDragging(false)
            accept(event.dataTransfer.files)
          }}
          className={cn(
            'flex flex-col items-center justify-center rounded-2xl border-2 border-dashed px-6 py-12 text-center transition',
            dragging ? 'scale-[1.01]' : '',
          )}
          style={
            dragging
              ? { borderColor: 'var(--brand)', background: 'var(--brand-soft)' }
              : undefined
          }
        >
          <ScanIllustration />
          <h3 className="mt-5 text-[18px] font-semibold tracking-[-0.01em]">
            Drop a receipt here
          </h3>
          <p className="mt-1.5 max-w-sm text-[14px] leading-relaxed text-[color:var(--text-muted)]">
            A photo or a PDF. SimpleBooks reads the vendor, date and total for you — you just
            check them.
          </p>
          <input
            ref={inputRef}
            type="file"
            accept={ACCEPTED}
            multiple
            className="hidden"
            onChange={(event) => accept(event.target.files)}
          />
          <Button variant="brand" size="lg" className="mt-6" onClick={() => inputRef.current?.click()}>
            <FileUp className="h-4 w-4" aria-hidden />
            Choose a file
          </Button>
          <p className="mt-4 text-[12.5px] text-[color:var(--text-subtle)]">
            PNG, JPG, WebP, TIFF or PDF · drop several at once to work through them
          </p>
        </div>
      ) : null}

      {phase === 'reading' ? (
        <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
          <div className="relative">
            <ScanLine className="h-12 w-12 text-[color:var(--brand)]" aria-hidden />
          </div>
          <h3 className="mt-5 text-[17px] font-semibold">{progress.stage || 'Reading…'}</h3>
          <div
            className="mt-4 h-1.5 w-64 overflow-hidden rounded-full"
            role="progressbar"
            aria-valuenow={progress.percent}
            aria-valuemin={0}
            aria-valuemax={100}
          >
            <div
              className="h-full rounded-full transition-all duration-300"
              style={{ width: `${Math.max(6, progress.percent)}%`, background: 'var(--brand)' }}
            />
          </div>
          <p className="mt-4 max-w-xs text-[13px] text-[color:var(--text-muted)]">
            The very first scan also downloads the language model, so give it a moment.
          </p>
        </div>
      ) : null}

      {phase === 'review' && draft ? (
        <div className="grid grid-cols-1 gap-6 md:grid-cols-[1fr_15rem]">
          <div className="space-y-4">
            <div className="flex items-center gap-2 rounded-xl px-3.5 py-2.5 text-[13.5px]" style={{ background: 'var(--brand-soft)' }}>
              <Sparkles className="h-4 w-4 shrink-0 text-[color:var(--brand)]" aria-hidden />
              <span>
                Read with {confidence}% confidence.{' '}
                <span className="text-[color:var(--text-muted)]">
                  {confidence >= 70 ? 'Looks clean — give it a glance.' : 'Worth double-checking.'}
                </span>
              </span>
            </div>

            <Field label="Vendor" required>
              <Input
                value={draft.vendor}
                onChange={(event) => patch({ vendor: event.target.value })}
                placeholder="Who was this paid to?"
                autoFocus
              />
            </Field>

            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Field label="Date">
                <Input
                  type="date"
                  value={draft.date}
                  max={today()}
                  onChange={(event) => patch({ date: event.target.value })}
                />
              </Field>
              <Field label="Category">
                <Select
                  value={draft.category}
                  onChange={(event) => patch({ category: event.target.value })}
                >
                  {EXPENSE_CATEGORIES.map((category) => (
                    <option key={category} value={category}>
                      {category}
                    </option>
                  ))}
                </Select>
              </Field>
              <Field label="Total paid" required>
                <MoneyInput
                  symbol={symbol}
                  value={draft.total}
                  min="0"
                  onChange={(event) => patch({ total: Number(event.target.value) })}
                />
              </Field>
              <Field label="Tax included" hint="Leave at 0 if you are not sure.">
                <MoneyInput
                  symbol={symbol}
                  value={draft.taxAmount}
                  min="0"
                  onChange={(event) => patch({ taxAmount: Number(event.target.value) })}
                />
              </Field>
              <Field label="Paid by">
                <Select
                  value={draft.paymentMethod}
                  onChange={(event) => patch({ paymentMethod: event.target.value })}
                >
                  {PAYMENT_METHODS.map((method) => (
                    <option key={method} value={method}>
                      {method}
                    </option>
                  ))}
                </Select>
              </Field>
            </div>

            <Field label="Notes">
              <Textarea
                rows={2}
                value={draft.notes}
                onChange={(event) => patch({ notes: event.target.value })}
                placeholder="What was this for?"
              />
            </Field>
          </div>

          <div>
            <p className="mb-2 text-[12px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              The scan
            </p>
            {image ? (
              <img
                src={image}
                alt="Scanned receipt"
                className="max-h-72 w-full rounded-xl border object-contain"
                style={{ background: 'var(--surface-2)' }}
              />
            ) : null}
            {ocrText ? (
              <details className="mt-3">
                <summary className="cursor-pointer text-[13px] font-medium text-[color:var(--text-muted)] hover:text-[color:var(--text)]">
                  Show the text we read
                </summary>
                <pre className="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded-lg border p-2.5 text-[11.5px] leading-relaxed text-[color:var(--text-muted)]">
                  {ocrText.trim() || 'Nothing legible was found.'}
                </pre>
              </details>
            ) : null}
          </div>
        </div>
      ) : null}
    </Modal>
  )
}
