import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Download, FileText, Mail, Pencil, Phone, Plus, Trash2 } from 'lucide-react'
import { Button, IconButton } from '../components/ui/Button'
import { Card } from '../components/ui/Card'
import { ClientIllustration, SearchIllustration } from '../components/ui/Illustrations'
import { EmptyState } from '../components/ui/EmptyState'
import { Field, Input, Textarea } from '../components/ui/Input'
import { Modal } from '../components/ui/Modal'
import { PageHeader } from '../components/PageHeader'
import { SearchInput } from '../components/ui/SearchInput'
import { CardsSkeleton } from '../components/ui/Skeleton'
import { useConfirm } from '../components/ui/Confirm'
import { db, newId } from '../db/db'
import { clientsToCsv } from '../lib/csv'
import { saveFile, slugify } from '../lib/download'
import { computeTotals, formatMoney, initials } from '../lib/format'
import { useApp } from '../store/useApp'
import { useActiveCompany, useClients, useDocuments } from '../store/useCompanyData'
import type { Client } from '../types'

/** Saved clients per company — a convenience list, never a source of truth. */
export function Clients() {
  const company = useActiveCompany()
  const clients = useClients()
  const documents = useDocuments()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const toast = useApp((s) => s.toast)
  const { confirm, dialog } = useConfirm()

  const [search, setSearch] = useState('')
  const [editing, setEditing] = useState<Client | null>(null)
  const [open, setOpen] = useState(false)

  // The command palette links here with ?new=1 to open the form directly.
  useEffect(() => {
    if (!searchParams.get('new')) return
    setEditing(null)
    setOpen(true)
    const next = new URLSearchParams(searchParams)
    next.delete('new')
    setSearchParams(next, { replace: true })
  }, [searchParams, setSearchParams])

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase()
    if (!needle) return clients ?? []
    return (clients ?? []).filter(
      (client) =>
        client.name.toLowerCase().includes(needle) ||
        (client.email ?? '').toLowerCase().includes(needle) ||
        client.addressLines.join(' ').toLowerCase().includes(needle),
    )
  }, [clients, search])

  if (!company || !clients || !documents) return <CardsSkeleton label="Loading clients" />

  /** How much this client has been billed, and how much is still owed. */
  const stats = (client: Client) => {
    const theirs = documents.filter((doc) => doc.clientId === client.id)
    const billed = theirs.reduce((sum, doc) => sum + computeTotals(doc).total, 0)
    const owed = theirs
      .filter((doc) => doc.kind === 'invoice' && doc.status === 'sent')
      .reduce((sum, doc) => sum + computeTotals(doc).total, 0)
    return { count: theirs.length, billed, owed }
  }

  const remove = async (client: Client) => {
    const theirs = documents.filter((doc) => doc.clientId === client.id).length
    const ok = await confirm({
      title: `Remove ${client.name}?`,
      message: theirs
        ? `Their ${theirs} ${theirs === 1 ? 'document' : 'documents'} will be kept exactly as they are — each one already stores its own copy of the client's details.`
        : 'This only removes them from your saved client list.',
      confirmLabel: 'Remove client',
      destructive: true,
    })
    if (!ok) return
    await db.clients.delete(client.id)
    toast(`${client.name} removed`, 'info')
  }

  const exportCsv = async () => {
    if (!clients.length) return
    const saved = await saveFile(
      `${slugify(company.name)}-clients.csv`,
      clientsToCsv(clients),
      'text/csv;charset=utf-8',
    )
    if (saved) toast(`Exported ${clients.length} clients`)
  }

  return (
    <div>
      <PageHeader
        title="Clients"
        subtitle={`Saved for ${company.name}. Nothing here is shared with your other companies.`}
        actions={
          <>
            {clients.length ? (
              <Button variant="secondary" onClick={exportCsv}>
                <Download className="h-4 w-4" aria-hidden />
                Export CSV
              </Button>
            ) : null}
            <Button
              variant="brand"
              onClick={() => {
                setEditing(null)
                setOpen(true)
              }}
            >
              <Plus className="h-4 w-4" aria-hidden />
              New client
            </Button>
          </>
        }
      />

      {clients.length === 0 ? (
        <Card padded={false}>
          <EmptyState
            illustration={<ClientIllustration />}
            title="No saved clients yet"
            description="Save a client once and they are one click away on every future invoice. You can also just type a name straight onto an invoice — saving is optional."
            action={
              <Button
                variant="brand"
                size="lg"
                onClick={() => {
                  setEditing(null)
                  setOpen(true)
                }}
              >
                <Plus className="h-4 w-4" aria-hidden />
                Add your first client
              </Button>
            }
            secondaryAction={
              <Button variant="secondary" size="lg" onClick={() => navigate('/invoices/new')}>
                Create an invoice instead
              </Button>
            }
          />
        </Card>
      ) : (
        <>
          <div className="mb-4 flex justify-end">
            <SearchInput
              value={search}
              onChange={setSearch}
              placeholder="Search clients…"
              className="w-full sm:w-72"
            />
          </div>

          {filtered.length ? (
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
              {filtered.map((client) => {
                const { count, billed, owed } = stats(client)
                return (
                  <Card key={client.id} className="group flex flex-col gap-4">
                    <div className="flex items-start gap-3">
                      <span
                        className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-[14px] font-semibold"
                        style={{ background: 'var(--brand-soft)', color: 'var(--brand)' }}
                        aria-hidden
                      >
                        {initials(client.name)}
                      </span>
                      <div className="min-w-0 flex-1">
                        <h3 className="truncate text-[15.5px] font-semibold tracking-[-0.01em]">
                          {client.name}
                        </h3>
                        {client.addressLines.length ? (
                          <p className="mt-0.5 truncate text-[13px] text-[color:var(--text-muted)]">
                            {client.addressLines.join(', ')}
                          </p>
                        ) : null}
                      </div>
                      <div className="flex shrink-0 gap-0.5 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100">
                        <IconButton
                          variant="ghost"
                          size="sm"
                          onClick={() => {
                            setEditing(client)
                            setOpen(true)
                          }}
                          aria-label={`Edit ${client.name}`}
                        >
                          <Pencil className="h-4 w-4" aria-hidden />
                        </IconButton>
                        <IconButton
                          variant="ghost"
                          size="sm"
                          onClick={() => void remove(client)}
                          aria-label={`Remove ${client.name}`}
                          className="hover:text-red-600"
                        >
                          <Trash2 className="h-4 w-4" aria-hidden />
                        </IconButton>
                      </div>
                    </div>

                    <div className="space-y-1 text-[13px]">
                      {client.email ? (
                        <a
                          href={`mailto:${client.email}`}
                          className="flex items-center gap-2 truncate text-[color:var(--text-muted)] transition hover:text-[color:var(--brand)]"
                        >
                          <Mail className="h-3.5 w-3.5 shrink-0" aria-hidden />
                          <span className="truncate">{client.email}</span>
                        </a>
                      ) : null}
                      {client.phone ? (
                        <span className="flex items-center gap-2 text-[color:var(--text-muted)]">
                          <Phone className="h-3.5 w-3.5 shrink-0" aria-hidden />
                          {client.phone}
                        </span>
                      ) : null}
                    </div>

                    {client.notes ? (
                      <p className="text-[13px] leading-relaxed text-[color:var(--text-muted)]">
                        {client.notes}
                      </p>
                    ) : null}

                    <div className="mt-auto flex items-end justify-between gap-3 border-t pt-3.5">
                      <div>
                        <div className="tabular text-[15px] font-semibold">
                          {formatMoney(billed, company.currency)}
                        </div>
                        <div className="text-[12px] text-[color:var(--text-subtle)]">
                          billed across {count} {count === 1 ? 'document' : 'documents'}
                          {owed > 0 ? ` · ${formatMoney(owed, company.currency)} owed` : ''}
                        </div>
                      </div>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => navigate(`/invoices/new?client=${client.id}`)}
                        title={`New invoice for ${client.name}`}
                      >
                        <FileText className="h-3.5 w-3.5" aria-hidden />
                        Invoice
                      </Button>
                    </div>
                  </Card>
                )
              })}
            </div>
          ) : (
            <Card padded={false}>
              <EmptyState
                illustration={<SearchIllustration />}
                title="No clients match that search"
                description="Check the spelling, or clear the search box to see everyone again."
                action={
                  <Button variant="secondary" onClick={() => setSearch('')}>
                    Clear search
                  </Button>
                }
              />
            </Card>
          )}
        </>
      )}

      <ClientDialog
        open={open}
        onClose={() => {
          setOpen(false)
          setEditing(null)
        }}
        companyId={company.id}
        client={editing}
      />
      {dialog}
    </div>
  )
}

function ClientDialog({
  open,
  onClose,
  companyId,
  client,
}: {
  open: boolean
  onClose: () => void
  companyId: string
  client: Client | null
}) {
  const toast = useApp((s) => s.toast)
  const [draft, setDraft] = useState<Client | null>(null)
  const [error, setError] = useState<string>()
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!open) return
    setError(undefined)
    setDraft(
      client
        ? structuredClone(client)
        : {
            id: newId(),
            companyId,
            name: '',
            addressLines: [],
            createdAt: new Date().toISOString(),
          },
    )
  }, [open, client, companyId])

  if (!draft) return null
  const patch = (changes: Partial<Client>) => setDraft({ ...draft, ...changes })

  const save = async () => {
    if (!draft.name.trim()) {
      setError('A name is all we really need.')
      return
    }
    setSaving(true)
    try {
      await db.clients.put({
        ...draft,
        name: draft.name.trim(),
        email: draft.email?.trim() || undefined,
        phone: draft.phone?.trim() || undefined,
        notes: draft.notes?.trim() || undefined,
        addressLines: draft.addressLines.map((line) => line.trim()).filter(Boolean),
      })
      toast(client ? 'Client updated' : `${draft.name.trim()} saved`)
      onClose()
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={client ? 'Edit client' : 'New client'}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="brand" onClick={save} loading={saving}>
            {client ? 'Save changes' : 'Add client'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Name" required error={error}>
          <Input
            value={draft.name}
            onChange={(event) => {
              patch({ name: event.target.value })
              setError(undefined)
            }}
            placeholder="Harbor & Finch Coffee"
            autoFocus
          />
        </Field>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label="Email">
            <Input
              type="email"
              value={draft.email ?? ''}
              onChange={(event) => patch({ email: event.target.value })}
              placeholder="ap@example.com"
            />
          </Field>
          <Field label="Phone">
            <Input
              value={draft.phone ?? ''}
              onChange={(event) => patch({ phone: event.target.value })}
              placeholder="(206) 555-0733"
            />
          </Field>
        </div>
        <Field label="Address" hint="One line per line.">
          <Textarea
            rows={3}
            value={draft.addressLines.join('\n')}
            onChange={(event) => patch({ addressLines: event.target.value.split('\n') })}
            placeholder={'310 Pike Street\nSeattle, WA 98101'}
          />
        </Field>
        <Field label="Notes" hint="Only you see this.">
          <Textarea
            rows={2}
            value={draft.notes ?? ''}
            onChange={(event) => patch({ notes: event.target.value })}
            placeholder="Purchase order required on every invoice."
          />
        </Field>
      </div>
    </Modal>
  )
}
