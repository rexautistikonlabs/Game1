import { GripVertical, Percent, Plus, Trash2 } from 'lucide-react'
import { Button, IconButton } from './ui/Button'
import { Input, MoneyInput } from './ui/Input'
import { currencySymbol, formatMoney, lineTotal } from '../lib/format'
import { newId } from '../db/db'
import type { LineItem } from '../types'

/**
 * The line-item grid. Every cell edits in place, totals update as you type,
 * and there is exactly one button to learn: "Add line".
 */
export function LineItemsEditor({
  items,
  currency,
  defaultTaxRate,
  showTax,
  onChange,
  onToggleTax,
}: {
  items: LineItem[]
  currency: string
  defaultTaxRate: number
  showTax: boolean
  onChange: (items: LineItem[]) => void
  /** Omit to fix the tax column in place. */
  onToggleTax?: () => void
}) {
  const symbol = currencySymbol(currency)

  const update = (id: string, changes: Partial<LineItem>) =>
    onChange(items.map((item) => (item.id === id ? { ...item, ...changes } : item)))

  const remove = (id: string) => onChange(items.filter((item) => item.id !== id))

  const add = () =>
    onChange([
      ...items,
      { id: newId(), description: '', quantity: 1, unitPrice: 0, taxRate: defaultTaxRate },
    ])

  const move = (index: number, direction: -1 | 1) => {
    const target = index + direction
    if (target < 0 || target >= items.length) return
    const next = [...items]
    ;[next[index], next[target]] = [next[target]!, next[index]!]
    onChange(next)
  }

  return (
    <div>
      {/* Column headings, desktop only — on narrow screens each row is a card. */}
      <div
        className={`hidden gap-2 px-1 pb-1.5 text-[11.5px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)] md:grid ${
          showTax
            ? 'md:grid-cols-[1.5rem_1fr_5rem_8rem_5.5rem_7rem_2.5rem]'
            : 'md:grid-cols-[1.5rem_1fr_5rem_8rem_7rem_2.5rem]'
        }`}
      >
        <span />
        <span>Description</span>
        <span className="text-right">Qty</span>
        <span className="text-right">Unit price</span>
        {showTax ? <span className="text-right">Tax %</span> : null}
        <span className="text-right">Amount</span>
        <span />
      </div>

      <div className="space-y-2">
        {items.map((item, index) => (
          <div
            key={item.id}
            className={`grid items-center gap-2 rounded-xl border p-2.5 md:border-0 md:p-0 ${
              showTax
                ? 'md:grid-cols-[1.5rem_1fr_5rem_8rem_5.5rem_7rem_2.5rem]'
                : 'md:grid-cols-[1.5rem_1fr_5rem_8rem_7rem_2.5rem]'
            }`}
          >
            <button
              type="button"
              onClick={() => move(index, index === items.length - 1 ? -1 : 1)}
              className="hidden h-9 w-6 items-center justify-center rounded text-[color:var(--text-subtle)] transition hover:text-[color:var(--text)] md:flex"
              aria-label={`Move line ${index + 1}`}
              title="Reorder"
            >
              <GripVertical className="h-4 w-4" aria-hidden />
            </button>

            <Input
              value={item.description}
              onChange={(event) => update(item.id, { description: event.target.value })}
              placeholder="What are you charging for?"
              aria-label={`Line ${index + 1} description`}
            />

            <Input
              type="number"
              step="any"
              min="0"
              value={item.quantity}
              onChange={(event) => update(item.id, { quantity: Number(event.target.value) })}
              className="tabular text-right"
              aria-label={`Line ${index + 1} quantity`}
            />

            <MoneyInput
              symbol={symbol}
              value={item.unitPrice}
              min="0"
              onChange={(event) => update(item.id, { unitPrice: Number(event.target.value) })}
              aria-label={`Line ${index + 1} unit price`}
            />

            {showTax ? (
              <Input
                type="number"
                step="0.01"
                min="0"
                max="100"
                value={item.taxRate}
                onChange={(event) => update(item.id, { taxRate: Number(event.target.value) })}
                className="tabular text-right"
                aria-label={`Line ${index + 1} tax rate`}
              />
            ) : null}

            <div className="tabular px-1 text-right text-[14.5px] font-semibold">
              {formatMoney(lineTotal(item), currency)}
            </div>

            <IconButton
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => remove(item.id)}
              disabled={items.length === 1}
              aria-label={`Remove line ${index + 1}`}
              title={items.length === 1 ? 'Keep at least one line' : 'Remove line'}
              className="justify-self-end text-[color:var(--text-subtle)] hover:text-red-600"
            >
              <Trash2 className="h-4 w-4" aria-hidden />
            </IconButton>
          </div>
        ))}
      </div>

      <div className="mt-3 flex items-center gap-1">
        <Button type="button" variant="ghost" size="sm" onClick={add}>
          <Plus className="h-4 w-4" aria-hidden />
          Add line
        </Button>
        {onToggleTax ? (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={onToggleTax}
            className="text-[color:var(--text-muted)]"
          >
            <Percent className="h-3.5 w-3.5" aria-hidden />
            {showTax ? 'Hide tax' : 'Add tax'}
          </Button>
        ) : null}
      </div>
    </div>
  )
}
