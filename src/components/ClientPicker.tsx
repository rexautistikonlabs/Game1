import { UserPlus } from 'lucide-react'
import { Field, Input, Select, Textarea } from './ui/Input'
import type { Client, PartySnapshot } from '../types'

/**
 * Pick a saved client, or just type who this is for. Saved clients are a
 * convenience — never a requirement — so a one-off invoice stays a 10-second job.
 */
export function ClientPicker({
  clients,
  value,
  clientId,
  onChange,
  saveToClients,
  onSaveToClientsChange,
  label,
  error,
}: {
  clients: Client[]
  value: PartySnapshot
  clientId?: string
  onChange: (party: PartySnapshot, clientId?: string) => void
  saveToClients: boolean
  onSaveToClientsChange: (save: boolean) => void
  label: string
  error?: string
}) {
  const selectSaved = (id: string) => {
    if (!id) {
      onChange({ name: '', email: '', phone: '', addressLines: [] }, undefined)
      return
    }
    const client = clients.find((c) => c.id === id)
    if (!client) return
    onChange(
      {
        name: client.name,
        email: client.email,
        phone: client.phone,
        addressLines: client.addressLines,
      },
      client.id,
    )
  }

  const patch = (changes: Partial<PartySnapshot>) => {
    // Hand-editing the details detaches the document from the saved client, so
    // history is never rewritten behind your back.
    onChange({ ...value, ...changes }, undefined)
  }

  return (
    <div className="space-y-4">
      {clients.length > 0 ? (
        <Field label="Saved clients" hint="Or type the details below for a one-off.">
          <Select value={clientId ?? ''} onChange={(event) => selectSaved(event.target.value)}>
            <option value="">Choose a client…</option>
            {clients.map((client) => (
              <option key={client.id} value={client.id}>
                {client.name}
              </option>
            ))}
          </Select>
        </Field>
      ) : null}

      <Field label={label} required error={error}>
        <Input
          value={value.name}
          onChange={(event) => patch({ name: event.target.value })}
          placeholder="Harbor & Finch Coffee"
        />
      </Field>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Email" hint="Used when you email the document.">
          <Input
            type="email"
            value={value.email ?? ''}
            onChange={(event) => patch({ email: event.target.value })}
            placeholder="ap@example.com"
          />
        </Field>
        <Field label="Phone">
          <Input
            value={value.phone ?? ''}
            onChange={(event) => patch({ phone: event.target.value })}
            placeholder="(206) 555-0733"
          />
        </Field>
      </div>

      <Field label="Address" hint="One line per line.">
        <Textarea
          rows={2}
          value={value.addressLines.join('\n')}
          onChange={(event) =>
            patch({ addressLines: event.target.value.split('\n') })
          }
          placeholder={'310 Pike Street\nSeattle, WA 98101'}
        />
      </Field>

      {!clientId && value.name.trim() ? (
        <label className="flex cursor-pointer items-center gap-2.5 rounded-xl border px-3.5 py-3 transition hover:bg-black/[0.02] dark:hover:bg-white/[0.04]">
          <input
            type="checkbox"
            checked={saveToClients}
            onChange={(event) => onSaveToClientsChange(event.target.checked)}
            className="h-4 w-4 accent-[color:var(--brand)]"
          />
          <UserPlus className="h-4 w-4 text-[color:var(--text-subtle)]" aria-hidden />
          <span className="text-[14px]">
            Save <span className="font-medium">{value.name.trim()}</span> to my clients
          </span>
        </label>
      ) : null}
    </div>
  )
}
