import { useState } from 'react'
import { ChevronDown, ChevronUp, Pencil, Plus, RotateCcw, Trash2, X } from 'lucide-react'
import { Button, IconButton } from './ui/Button'
import { Input } from './ui/Input'
import { SectionTitle } from './ui/Card'
import { useConfirm } from './ui/Confirm'
import { db, newId } from '../db/db'
import { useApp } from '../store/useApp'
import { useCategories, useExpenses } from '../store/useCompanyData'
import { DEFAULT_EXPENSE_CATEGORIES, type Category, type Company } from '../types'

/**
 * Expense categories for one company. Expenses store the category *name*, so
 * renaming or deleting one never rewrites history — an old expense keeps saying
 * what it said. Renaming does offer to carry existing expenses across, because
 * that is almost always what someone fixing a typo wants.
 */
export function CategoryManager({ company }: { company: Company }) {
  const categories = useCategories()
  const expenses = useExpenses()
  const toast = useApp((s) => s.toast)
  const { confirm, dialog } = useConfirm()

  const [adding, setAdding] = useState('')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editingName, setEditingName] = useState('')

  if (!categories || !expenses) return null

  const usage = (name: string) => expenses.filter((expense) => expense.category === name).length

  const nameTaken = (name: string, exceptId?: string) =>
    categories.some(
      (category) =>
        category.id !== exceptId && category.name.toLowerCase() === name.trim().toLowerCase(),
    )

  const add = async () => {
    const name = adding.trim()
    if (!name) return
    if (nameTaken(name)) {
      toast(`${name} is already in the list.`, 'error')
      return
    }
    await db.categories.add({
      id: newId(),
      companyId: company.id,
      name,
      // New categories go to the end rather than jumping the list around.
      sortOrder: (categories.at(-1)?.sortOrder ?? -1) + 1,
      createdAt: new Date().toISOString(),
    })
    setAdding('')
    toast(`Added ${name}`)
  }

  const rename = async (category: Category) => {
    const name = editingName.trim()
    if (!name || name === category.name) {
      setEditingId(null)
      return
    }
    if (nameTaken(name, category.id)) {
      toast(`${name} is already in the list.`, 'error')
      return
    }

    const affected = usage(category.name)
    let moveExpenses = false
    if (affected > 0) {
      moveExpenses = await confirm({
        title: `Rename to ${name}?`,
        message: (
          <>
            {affected} {affected === 1 ? 'expense uses' : 'expenses use'}{' '}
            <strong>{category.name}</strong>. Move {affected === 1 ? 'it' : 'them'} to{' '}
            <strong>{name}</strong> as well?
          </>
        ),
        confirmLabel: `Rename and move ${affected}`,
        cancelLabel: 'Rename only',
      })
    }

    await db.transaction('rw', [db.categories, db.expenses], async () => {
      await db.categories.update(category.id, { name })
      if (moveExpenses) {
        const stale = expenses.filter((expense) => expense.category === category.name)
        await db.expenses.bulkPut(
          stale.map((expense) => ({
            ...expense,
            category: name,
            updatedAt: new Date().toISOString(),
          })),
        )
      }
    })
    setEditingId(null)
    toast(moveExpenses ? `Renamed, and moved ${affected}` : 'Category renamed')
  }

  const remove = async (category: Category) => {
    const affected = usage(category.name)
    const ok = await confirm({
      title: `Delete ${category.name}?`,
      message: affected
        ? `${affected} ${affected === 1 ? 'expense keeps' : 'expenses keep'} “${category.name}” as its category — nothing is lost. It just stops appearing in the dropdown for new expenses.`
        : 'It is not used by any expense.',
      confirmLabel: 'Delete category',
      destructive: true,
    })
    if (!ok) return
    await db.categories.delete(category.id)
    toast(`${category.name} removed`, 'info')
  }

  const move = async (index: number, direction: -1 | 1) => {
    const target = index + direction
    if (target < 0 || target >= categories.length) return
    const a = categories[index]!
    const b = categories[target]!
    // Swap the stored order rather than reindexing the whole list.
    await db.transaction('rw', db.categories, async () => {
      await db.categories.update(a.id, { sortOrder: b.sortOrder })
      await db.categories.update(b.id, { sortOrder: a.sortOrder })
    })
  }

  const restoreDefaults = async () => {
    const missing = DEFAULT_EXPENSE_CATEGORIES.filter(
      (name) => !categories.some((c) => c.name.toLowerCase() === name.toLowerCase()),
    )
    if (missing.length === 0) {
      toast('Every default category is already in your list.', 'info')
      return
    }
    const ok = await confirm({
      title: 'Add back the default categories?',
      message: `This adds ${missing.length} missing ${
        missing.length === 1 ? 'category' : 'categories'
      }: ${missing.join(', ')}. Nothing you have added is removed or renamed.`,
      confirmLabel: `Add ${missing.length}`,
    })
    if (!ok) return

    const now = new Date().toISOString()
    let order = (categories.at(-1)?.sortOrder ?? -1) + 1
    await db.categories.bulkAdd(
      missing.map((name) => ({
        id: newId(),
        companyId: company.id,
        name,
        sortOrder: order++,
        createdAt: now,
      })),
    )
    toast(`Added ${missing.length} ${missing.length === 1 ? 'category' : 'categories'}`)
  }

  return (
    <div className="space-y-5">
      <SectionTitle
        title="Expense categories"
        subtitle={`Used when you record or scan an expense for ${company.name}.`}
        action={
          <Button variant="ghost" size="sm" onClick={restoreDefaults}>
            <RotateCcw className="h-3.5 w-3.5" aria-hidden />
            Restore defaults
          </Button>
        }
      />

      <ul className="divide-y">
        {categories.map((category, index) => {
          const count = usage(category.name)
          const isEditing = editingId === category.id
          return (
            <li key={category.id} className="group flex items-center gap-3 py-2">
              {isEditing ? (
                <>
                  <Input
                    value={editingName}
                    onChange={(event) => setEditingName(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter') void rename(category)
                      if (event.key === 'Escape') setEditingId(null)
                    }}
                    aria-label={`Rename ${category.name}`}
                    autoFocus
                  />
                  <Button size="sm" variant="brand" onClick={() => void rename(category)}>
                    Save
                  </Button>
                  <IconButton
                    size="sm"
                    variant="ghost"
                    onClick={() => setEditingId(null)}
                    aria-label="Cancel rename"
                  >
                    <X className="h-4 w-4" aria-hidden />
                  </IconButton>
                </>
              ) : (
                <>
                  <span className="min-w-0 flex-1 truncate text-[14.5px]">{category.name}</span>
                  <span className="tabular shrink-0 text-[12.5px] text-[color:var(--text-subtle)]">
                    {count ? `${count} ${count === 1 ? 'expense' : 'expenses'}` : '—'}
                  </span>
                  <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100">
                    <IconButton
                      size="sm"
                      variant="ghost"
                      onClick={() => void move(index, -1)}
                      disabled={index === 0}
                      aria-label={`Move ${category.name} up`}
                    >
                      <ChevronUp className="h-4 w-4" aria-hidden />
                    </IconButton>
                    <IconButton
                      size="sm"
                      variant="ghost"
                      onClick={() => void move(index, 1)}
                      disabled={index === categories.length - 1}
                      aria-label={`Move ${category.name} down`}
                    >
                      <ChevronDown className="h-4 w-4" aria-hidden />
                    </IconButton>
                    <IconButton
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        setEditingId(category.id)
                        setEditingName(category.name)
                      }}
                      aria-label={`Rename ${category.name}`}
                    >
                      <Pencil className="h-4 w-4" aria-hidden />
                    </IconButton>
                    <IconButton
                      size="sm"
                      variant="ghost"
                      onClick={() => void remove(category)}
                      aria-label={`Delete ${category.name}`}
                      className="hover:text-red-600"
                    >
                      <Trash2 className="h-4 w-4" aria-hidden />
                    </IconButton>
                  </div>
                </>
              )}
            </li>
          )
        })}
      </ul>

      {categories.length === 0 ? (
        <p className="rounded-xl border border-dashed px-4 py-6 text-center text-[14px] text-[color:var(--text-muted)]">
          No categories yet. Add one below, or restore the defaults.
        </p>
      ) : null}

      <div className="flex gap-2">
        <Input
          value={adding}
          onChange={(event) => setAdding(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') void add()
          }}
          placeholder="Add a category…"
          aria-label="New category name"
        />
        <Button variant="secondary" onClick={add} disabled={!adding.trim()}>
          <Plus className="h-4 w-4" aria-hidden />
          Add
        </Button>
      </div>

      {dialog}
    </div>
  )
}
