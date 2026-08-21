import { useEffect, useState } from 'react'
import { Button } from './ui/Button'
import { Field, Input, MoneyInput, Select, Textarea } from './ui/Input'
import { Modal } from './ui/Modal'
import { db, newId } from '../db/db'
import { currencySymbol, today } from '../lib/format'
import { useApp } from '../store/useApp'
import { EXPENSE_CATEGORIES, PAYMENT_METHODS, type Company, type Expense } from '../types'

/** Add or edit an expense by hand — the path for anything without a scan. */
export function ExpenseDialog({
  open,
  onClose,
  company,
  expense,
}: {
  open: boolean
  onClose: () => void
  company: Company
  /** Omit to create a new expense. */
  expense?: Expense
}) {
  const toast = useApp((s) => s.toast)
  const [draft, setDraft] = useState<Expense | null>(null)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!open) return
    const now = new Date().toISOString()
    setDraft(
      expense
        ? structuredClone(expense)
        : {
            id: newId(),
            companyId: company.id,
            vendor: '',
            date: today(),
            total: 0,
            taxAmount: 0,
            category: 'Other',
            currency: company.currency,
            paymentMethod: 'Card',
            source: 'manual',
            createdAt: now,
            updatedAt: now,
          },
    )
  }, [open, expense, company])

  if (!draft) return null

  const patch = (changes: Partial<Expense>) => setDraft({ ...draft, ...changes })
  const symbol = currencySymbol(draft.currency)

  const save = async () => {
    if (!draft.vendor.trim()) {
      toast('Who was this paid to?', 'error')
      return
    }
    setSaving(true)
    try {
      await db.expenses.put({
        ...draft,
        vendor: draft.vendor.trim(),
        notes: draft.notes?.trim() || undefined,
        total: Number(draft.total) || 0,
        taxAmount: Number(draft.taxAmount) || 0,
        updatedAt: new Date().toISOString(),
      })
      toast(expense ? 'Expense updated' : `Saved ${draft.vendor.trim()} to expenses`)
      onClose()
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Could not save that expense.', 'error')
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={expense ? 'Edit expense' : 'Add an expense'}
      description={`Recorded under ${company.name}.`}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="brand" onClick={save} loading={saving}>
            {expense ? 'Save changes' : 'Add expense'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Vendor" required>
          <Input
            value={draft.vendor}
            onChange={(event) => patch({ vendor: event.target.value })}
            placeholder="Rose City Print Shop"
            autoFocus
          />
        </Field>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label="Date">
            <Input
              type="date"
              value={draft.date}
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
              value={draft.paymentMethod ?? ''}
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
            value={draft.notes ?? ''}
            onChange={(event) => patch({ notes: event.target.value })}
            placeholder="What was this for?"
          />
        </Field>
      </div>
    </Modal>
  )
}
